# frozen_string_literal: true

# scripts_packer.rb
#
# Pure-Ruby (de)serializer for RPG Maker VX Ace's Data/Scripts.rvdata2.
# Replaces the rvunpacker.exe used by the reference project, but only handles the
# Scripts archive (which is all the patcher needs).
#
# Scripts.rvdata2 is `Marshal.dump`-ed Array of [magic_id, name, zlib_code], where
# `zlib_code` is the script's UTF-8 source compressed with Zlib (deflate).
#
# Usage:
#   ruby scripts_packer.rb decode <game_root>   # rvdata2 -> Scripts/*.rb (+ index)
#   ruby scripts_packer.rb encode <game_root>   # Scripts/*.rb (+ index) -> rvdata2
#
# decode writes:
#   <root>/Scripts/<NNNN>_<sanitized-name>.rb   the editable source files
#   <root>/Scripts/.index.marshal              ordering + original magic ids/names
# encode reads those back and rebuilds <root>/Data/Scripts.rvdata2 faithfully.

require "zlib"
require "fileutils"

module ScriptsPacker
  SCRIPTS_RVDATA2 = File.join("Data", "Scripts.rvdata2")
  SCRIPTS_DIR     = "Scripts"
  INDEX_FILE      = ".index.marshal"

  module_function

  def scripts_path(root)
    File.join(root, SCRIPTS_RVDATA2)
  end

  def scripts_dir(root)
    File.join(root, SCRIPTS_DIR)
  end

  def index_path(root)
    File.join(scripts_dir(root), INDEX_FILE)
  end

  # Make a script name safe for a filename while keeping it human-readable.
  def sanitize(name)
    cleaned = name.to_s.strip
    cleaned = "Untitled" if cleaned.empty?
    cleaned.gsub(/[^0-9A-Za-z_\- ]/, "_").gsub(/\s+/, "_")
  end

  def decode(root)
    src = scripts_path(root)
    raise "Not found: #{src}" unless File.file?(src)

    entries = Marshal.load(File.binread(src))
    dir = scripts_dir(root)
    FileUtils.mkdir_p(dir)

    index = []
    entries.each_with_index do |(magic, name, deflated), i|
      code = Zlib::Inflate.inflate(deflated)
      code.force_encoding("UTF-8")

      filename = format("%04d_%s.rb", i, sanitize(name))
      File.binwrite(File.join(dir, filename), code)

      index << { magic: magic, name: name.to_s, file: filename }
    end

    File.binwrite(index_path(root), Marshal.dump(index))
    puts "Decoded #{index.length} scripts to #{dir}"
  end

  def encode(root)
    idx_path = index_path(root)
    raise "Missing index: #{idx_path} (run `decode` first)" unless File.file?(idx_path)

    index = Marshal.load(File.binread(idx_path))
    dir = scripts_dir(root)

    entries = index.map do |meta|
      file = File.join(dir, meta[:file])
      raise "Missing script file: #{file}" unless File.file?(file)

      code = File.binread(file)
      # RGSS stores source as UTF-8 bytes; deflate the raw bytes.
      deflated = Zlib::Deflate.deflate(code, Zlib::DEFAULT_COMPRESSION)
      [meta[:magic], meta[:name], deflated]
    end

    dst = scripts_path(root)
    FileUtils.mkdir_p(File.dirname(dst))
    File.binwrite(dst, Marshal.dump(entries))
    puts "Encoded #{entries.length} scripts to #{dst}"
  end

  def run(action, root)
    case action
    when "decode" then decode(root)
    when "encode" then encode(root)
    else raise "Unknown action: #{action.inspect} (expected decode|encode)"
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  action = (ARGV[0] || "decode").downcase
  root = ARGV[1] || "."
  begin
    ScriptsPacker.run(action, root)
  rescue StandardError => e
    warn "scripts_packer: #{e.message}"
    exit 1
  end
end
