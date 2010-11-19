require 'tmpdir'

class String
  # Does same basic string replacements to ensure valid filenames.
  def escape_filename
    mgsub([[/[\s\:\)\(\/\?\,]+/, "-"], [/\*/, "star"], [/\./,""]])
  end
  
  # Does some basic string replacements to ensure valid directory names.
  def escape_dirname
    mgsub( [ [/[\s\:\)\(\?\,]+/, "-"], [/\*/, "star"] ] )
  end
  
  
  # gsub multiple pairs of regexp's
  def mgsub(key_value_pairs=[].freeze)
    regexp_fragments = key_value_pairs.collect { |k,v| k }
    gsub(Regexp.union(*regexp_fragments)) do |match|
      key_value_pairs.detect { |k,v| k =~ match}[1]
    end
  end
  
end

class Pathname
  MIN_PFILE_SIZE = 10_000_000
  
  def each_subdirectory
    each_entry do |leaf|
      next if leaf.to_s =~ /^\./
      branch = self + leaf
      next if not branch.directory?
      next if branch.symlink?
      branch.each_subdirectory { |subbranch| yield subbranch }
      yield branch
    end
  end
  
  def each_pfile(min_file_size = MIN_PFILE_SIZE)
    entries.each do |leaf|
      next unless leaf.to_s =~ /^P.{5}\.7(\.bz2)/
      branch = self + leaf
      next if branch.symlink?
      if branch.size >= min_file_size
        lc = branch.local_copy
        begin
          yield lc
        rescue StandardError => e
          puts "#{e}"
        ensure
          lc.delete
        end
      end
    end
  end
  
  def first_dicom
    entries.each do |leaf|
      branch = self + leaf
      if leaf.to_s =~ /^I\.(\.bz2)?$|\.dcm(\.bz2)?$|[A-Za-z^P]\.[0-9]+(\.bz2)?$/
        lc = branch.local_copy
        begin
          yield lc
        rescue Exception => e
          puts "#{e}"
        ensure
          lc.delete
        end
        return
      end 
    end
  end
  
  def all_dicoms
    local_copies = []
    Dir.mktmpdir do |tempdir|
      begin
      
        entries.each do |leaf|
          branch = self + leaf
          if leaf.to_s =~ /^I\.(\.bz2)?$|\.dcm(\.bz2)?$|\.[0-9]+(\.bz2)?$/
            local_copies << branch.local_copy(tempdir)
          end
        end

        yield local_copies

      ensure
        local_copies.each { |lc| lc.delete }
      end
    end
    
    return
  end
  
  def recursive_local_copy(ignore_patterns = [], &block)
    tempdir = Dir.mktmpdir('local_orig')

    entries.each do |leaf|
      puts branch = self + leaf
      next if branch.directory?
      ignore_patterns.collect { |pat| next if leaf.to_s =~ pattern } 
      next if branch.should_be_skipped
      puts "Locally provisioning #{leaf}"
      lc = branch.local_copy(tempdir)
      lc.chmod(0444 | 0200 | 0020 )
    end
    
    return tempdir
  end
  
  def should_be_skipped
    self.to_s =~ /^\./ || self.symlink?
  end
  

  # Creates a local, unzipped copy of a file for use in scanning.
  # Will return a pathname to the local copy if called directly, or can also be 
  # passed a block.  If it is passed a block, it will create the local copy
  # and ensure the local copy is deleted.
  def local_copy(tempdir = Dir.mktmpdir, &block)
    tfbase = self.to_s =~ /\.bz2$/ ? self.basename.to_s.chomp(".bz2") : self.basename.to_s
    tfbase.escape_filename
    tmpfile = File.join(tempdir, tfbase)
    # puts tmpfile
    # puts File.exist?(tmpfile)
    File.delete(tmpfile) if File.exist?(tmpfile)
    if self.to_s =~ /\.bz2$/
      `bunzip2 -k -c '#{self.to_s}' >> '#{tmpfile}'`
    else
      FileUtils.cp(self.to_s, tmpfile)
    end

    lc = Pathname.new(tmpfile)
    
    if block
      begin
        yield lc
      ensure
        lc.delete
      end

    else
      return lc
    end
  end
  
end

# =begin rdoc
# Monkey-patch Float to avoid rounding errors.
# For more in-depth discussion, see: http://www.ruby-forum.com/topic/179361
# Currently not in use.
# =end
# class Float
#   def <=> other
#     puts epsilon = self * 1e-14
#     diff = self - other
#     # return -1 if diff > epsilon
#     # return 1 if diff < -epsilon
#     0
#   end
# 
#   def == other  #because built-in Float#== bypasses <=>
#     (self<=>other) == 0
#     true
#   end
# end


