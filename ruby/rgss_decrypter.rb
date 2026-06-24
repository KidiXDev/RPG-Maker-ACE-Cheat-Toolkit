# frozen_string_literal: true

# rgss_decrypter.rb
#
# Pure-Ruby extractor for RPG Maker RGSSAD archives.
# Replaces the third-party RPGMakerDecrypter-cli.exe used by the reference project.
#
# Supports:
#   - v1: Game.rgssad (XP) / Game.rgss2a (VX)
#   - v3: Game.rgss3a (VX Ace)
#
# Usage:
#   ruby rgss_decrypter.rb <game_root>
#
# It auto-detects the archive (Game.rgss3a, Game.rgss2a, or Game.rgssad) inside
# <game_root> and extracts every entry to disk relative to <game_root>, creating
# parent directories as needed. The game runs from these loose files once the
# archive itself is renamed away by the patcher.

require "fileutils"

module RGSSAD
  MAGIC = "RGSSAD\0".b

  # Mask helper to keep arithmetic inside 32 bits.
  def self.u32(value)
    value & 0xFFFFFFFF
  end

  # ---- v1 (XP / VX) -------------------------------------------------------
  # Sequential layout: each entry is [name_len][name][size][data]. A single key
  # stream (starting at 0xDEADCAFE) is consumed as the archive is read:
  #   - integers advance the key once per 32-bit value
  #   - filenames advance the key once per byte
  #   - file data advances the key once per 4 bytes (using the key's 4 LE bytes)
  V1_INITIAL_KEY = 0xDEADCAFE

  def self.extract_v1(io, root)
    @v1_key = V1_INITIAL_KEY
    entries = 0

    until io.eof?
      name_len = v1_decrypt_integer(io)
      break if name_len.nil?

      name_raw = io.read(name_len)
      break if name_raw.nil? || name_raw.bytesize < name_len
      name = v1_decrypt_name(name_raw)

      size = v1_decrypt_integer(io)
      break if size.nil?

      data = io.read(size) || +""
      write_entry(root, name, v1_decrypt_data(data))
      entries += 1
    end

    entries
  end

  def self.v1_decrypt_integer(io)
    raw = io.read(4)
    return nil if raw.nil? || raw.bytesize < 4

    value = raw.unpack1("V") ^ @v1_key
    @v1_key = u32(@v1_key * 7 + 3)
    value
  end

  def self.v1_decrypt_name(raw)
    name = +""
    raw.each_byte do |b|
      name << (b ^ (@v1_key & 0xFF)).chr
      @v1_key = u32(@v1_key * 7 + 3)
    end
    name.force_encoding("UTF-8")
  end

  def self.v1_decrypt_data(data)
    out = data.dup.b
    key = @v1_key
    key_bytes = [key].pack("V").bytes
    j = 0
    out.bytesize.times do |i|
      if j == 4
        j = 0
        key = u32(key * 7 + 3)
        key_bytes = [key].pack("V").bytes
      end
      out.setbyte(i, out.getbyte(i) ^ key_bytes[j])
      j += 1
    end
    out
  end

  # ---- v3 (VX Ace) --------------------------------------------------------
  # A header table lists every entry up front; offset == 0 terminates the table.
  # The header is XORed with a key derived from a 4-byte seed; file data is XORed
  # with a per-file key that advances key = key * 7 + 3 every 4 bytes.
  def self.extract_v3(io, root)
    seed = io.read(4).unpack1("V")
    base_key = u32(seed * 9 + 3)

    entries = []
    loop do
      offset    = read_xor_u32(io, base_key)
      size      = read_xor_u32(io, base_key)
      file_key  = read_xor_u32(io, base_key)
      name_len  = read_xor_u32(io, base_key)
      break if offset.nil? || offset.zero?

      name_raw = io.read(name_len)
      name = decrypt_name_v3(name_raw, base_key)

      entries << { name: name, offset: offset, size: size, key: file_key }
    end

    entries.each do |e|
      io.seek(e[:offset])
      data = io.read(e[:size]) || +""
      write_entry(root, e[:name], decrypt_data_v3(data, e[:key]))
    end

    entries.length
  end

  # In v3 the header key is constant; each 4-byte field is XORed with it.
  def self.read_xor_u32(io, key)
    raw = io.read(4)
    return nil if raw.nil? || raw.bytesize < 4

    raw.unpack1("V") ^ key
  end

  # Names are XORed byte-by-byte with the little-endian bytes of the constant key,
  # cycling through the 4 key bytes.
  def self.decrypt_name_v3(raw, key)
    key_bytes = [key].pack("V").bytes
    name = +""
    raw.each_byte.with_index do |b, i|
      name << (b ^ key_bytes[i % 4]).chr
    end
    name.force_encoding("UTF-8")
  end

  def self.decrypt_data_v3(data, file_key)
    out = data.dup.b
    key = u32(file_key)
    key_bytes = [key].pack("V").bytes
    out.bytesize.times do |i|
      out.setbyte(i, out.getbyte(i) ^ key_bytes[i % 4])
      if (i + 1) % 4 == 0
        key = u32(key * 7 + 3)
        key_bytes = [key].pack("V").bytes
      end
    end
    out
  end

  # ---- shared -------------------------------------------------------------
  def self.write_entry(root, name, data)
    # Archive paths use backslashes; normalize to the host separator and guard
    # against path traversal.
    safe = name.tr("\\", "/").gsub(%r{\A/+}, "")
    raise "unsafe path in archive: #{name.inspect}" if safe.split("/").include?("..")

    dest = File.join(root, safe)
    FileUtils.mkdir_p(File.dirname(dest))
    File.binwrite(dest, data)
    puts "  extracted #{safe} (#{data.bytesize} bytes)"
  end

  def self.find_archive(root)
    %w[Game.rgss3a Game.rgss2a Game.rgssad].each do |name|
      path = File.join(root, name)
      return path if File.file?(path)
    end
    nil
  end

  def self.run(root)
    archive = find_archive(root)
    raise "No RGSSAD archive (Game.rgss3a/rgss2a/rgssad) found in #{root}" if archive.nil?

    puts "Extracting #{archive} ..."
    count = File.open(archive, "rb") do |io|
      header = io.read(8)
      raise "Not an RGSSAD archive: #{archive}" unless header && header[0, 7] == MAGIC[0, 7]

      version = header.getbyte(7)
      case version
      when 1, 2 then extract_v1(io, root)
      when 3    then extract_v3(io, root)
      else raise "Unsupported RGSSAD version: #{version}"
      end
    end

    puts "Done. Extracted #{count} files."
  end
end

if __FILE__ == $PROGRAM_NAME
  root = ARGV[0] || "."
  begin
    RGSSAD.run(root)
  rescue StandardError => e
    warn "rgss_decrypter: #{e.message}"
    exit 1
  end
end
