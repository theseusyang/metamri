require 'rubygems'
require 'sqlite3'
require 'ftools'
require 'metamri/nifti_builder'

=begin rdoc
A #Dataset defines a single 3D or 4D image, i.e. either a volume or a time series
of volumes.  This encapsulation will provide easy manipulation of groups of raw
image files including basic reconstruction.
=end
class RawImageDataset

  # The directory that contains all the raw images and related files that make up
  # this data set.
  attr_reader :directory
  # An array of #RawImageFile objects that compose the complete data set.
  attr_reader :raw_image_files
  # From the first raw image file in the dataset
  attr_reader :series_description
  # From the first raw image file in the dataset
  attr_reader :rmr_number
  # From the first raw image file in the dataset
  attr_reader :timestamp
  # A key string unique to a dataset composed of the rmr number and the timestamp.
  attr_reader :dataset_key
  # the file scanned
  attr_reader :scanned_file
  # the scanner source
  attr_reader :scanner_source
  # A #RawImageDatasetThumbnail object that composes the thumbnail for the dataset.
  attr_reader :thumbnail

=begin rdoc
  * dir: The directory containing the files.
  * files: An array of #RawImageFile objects that compose the complete data set.
  
  Initialization raises errors in several cases:
  * directory doesn't exist => IOError
  * any of the raw image files is not actually a RawImageFile => IndexError
  * series description, rmr number, or timestamp cannot be extracted from the first RawImageFile => IndexError
=end
  def initialize(directory, raw_image_files)    
    @directory = File.expand_path(directory)
    raise(IOError, "#{@directory} not found.") if not File.directory?(@directory)
    raise(IOError, "No raw image files supplied.") unless raw_image_files
    
    # If only a single raw_image_file was supplied, put it into an array for processing.
    raw_image_files = [raw_image_files] if raw_image_files.class.to_s == "RawImageFile"

    raw_image_files.each do |im|
      raise(IndexError, im.to_s + " is not a RawImageFile") if im.class.to_s != "RawImageFile"
    end
    @raw_image_files = raw_image_files
    @series_description = @raw_image_files.first.series_description
    raise(IndexError, "No series description found") if @series_description.nil?
    @rmr_number = @raw_image_files.first.rmr_number
    raise(IndexError, "No rmr found") if @rmr_number.nil?
    @timestamp = get_earliest_timestamp
    raise(IndexError, "No timestamp found") if @timestamp.nil?
    @dataset_key = @rmr_number + "::" + @timestamp.to_s
    @scanned_file = @raw_image_files.first.filename
    raise(IndexError, "No scanned file found") if @scanned_file.nil?
    @scanner_source = @raw_image_files.first.source
    raise(IndexError, "No scanner source found") if @scanner_source.nil?
    
    $LOG ||= Logger.new(STDOUT)
  end

=begin rdoc
Generates an SQL insert statement for this dataset that can be used to populate
the Johnson Lab rails TransferScans application database backend.  The motivation
for this is that many dataset inserts can be collected into one db transaction
at the visit level, or even higher when doing a whole file system scan.
=end
  def db_insert(visit_id)
    "INSERT INTO image_datasets
    (rmr, series_description, path, timestamp, created_at, updated_at, visit_id, 
    glob, rep_time, bold_reps, slices_per_volume, scanned_file)
    VALUES ('#{@rmr_number}', '#{@series_description}', '#{@directory}', '#{@timestamp.to_s}', '#{DateTime.now}', 
    '#{DateTime.now}', '#{visit_id}', '#{self.glob}', '#{@raw_image_files.first.rep_time}', 
    '#{@raw_image_files.first.bold_reps}', '#{@raw_image_files.first.num_slices}', '#{@scanned_file}')"
  end
  
  def db_update(dataset_id)
    "UPDATE image_datasets SET
     rmr = '#{@rmr_number}',
     series_description = '#{@series_description}',
     path = '#{@directory}',
     timestamp = '#{@timestamp.to_s}',
     updated_at = '#{DateTime.now.to_s}',
     glob = '#{self.glob}',
     rep_time = '#{@raw_image_files.first.rep_time}',
     bold_reps = '#{@raw_image_files.first.bold_reps}',
     slices_per_volume = '#{@raw_image_files.first.num_slices}',
     scanned_file = '#{@scanned_file}'
     WHERE id = '#{dataset_id}'"
  end
  
  def db_fetch
    "SELECT * FROM image_datasets 
     WHERE rmr = '#{@rmr_number}' 
     AND path = '#{@directory}' 
     AND timestamp LIKE '#{@timestamp.to_s.split(/\+|Z/).first}%'"
  end

=begin rdoc
Returns a hash of attributes used for insertion into active record.
Options:  :thumb => FileHandle to thumbnail includes a thumbnail.
=end  
  def attributes_for_active_record(options = {})
    thumbnail = options.has_key?(:thumb) ? options[:thumb] : nil
    
    unless (thumbnail.class == File || thumbnail == nil)
      raise(IOError, "Thumbnail #{options[:thumb]} must be a #File.")
    end
    { :rmr => @rmr_number,
      :series_description => @series_description,
      :path => @directory,
      :timestamp => @timestamp.to_s,
      :glob => glob,
      :rep_time => @raw_image_files.first.rep_time,
      :bold_reps => @raw_image_files.first.bold_reps,
      :slices_per_volume => @raw_image_files.first.num_slices,
      :scanned_file => @scanned_file,
      :thumbnail => thumbnail
    }
  end
  
  def create_thumbnail
    @thumbnail = RawImageDatasetThumbnail.new(self)
    @thumbnail.create_thumbnail
  end

  def thumbnail_for_active_record
    # Ensure a thumbnail has been created.
    create_thumbnail unless @thumbnail
    return File.open(@thumbnail.path)
  end

=begin rdoc
Implements an api for changing image datasets into usable nifti files.
Pass in an output path and filename.
The to3d code is applied as a mixed-in module.
Returns the to3d command that creates the specified options.
=end
  def to_nifti(nifti_output_directory, nifti_filename, input_options = {} )
    
    # Handle the business logic for choosing the right Nifti Builder here.
    # Currently just extend the default unknown builder, since that's the only one that exists.
    if true
      nifti_output_directory = File.join(nifti_output_directory, 'unknown') if input_options[:append_modality_directory]
      extend(UnknownImageDataset)
    end
    
    nifti_conversion_command, nifti_output_file = self.dataset_to_nifti(nifti_output_directory, nifti_filename, input_options)
    return nifti_conversion_command, nifti_output_file
  end

=begin rdoc
Uses to3d to create the nifti file as specified by to_nifti.

Returns a path to the created dataset as a string if successful.
=end
  def to_nifti!(nifti_output_directory, nifti_filename, input_options = {} )
    begin 
      nifti_conversion_command, nifti_output_file = to_nifti(nifti_output_directory, nifti_filename, input_options)
      puts nifti_conversion_command
      system "#{nifti_conversion_command}"
      raise(IOError, "Could not convert image dataset: #{@directory} to #{nifti_output_file}") unless $? == 0
    rescue IOError => e
      $LOG.warn "-- Warning: #{e.message}"
    end
    return nifti_conversion_command, nifti_output_file
  end

=begin rdoc
Returns a globbing wildcard that is used by to3D to gather files for
reconstruction.  If no compatible glob is found for the data set, nil is returned.
This is always the case for pfiles. For example if the first file in a data set is I.001, then:
<tt>dataset.glob</tt>
<tt>=> "I.*"</tt>
including the quotes, which are necessary becuase some data sets (functional dicoms)
have more component files than shell commands can handle.
=end
  def glob
    case @raw_image_files.first.filename
    when /^E.*dcm$/
      return 'E*.dcm'
    when /\.dcm$/
      return '*.dcm'
    when /^I\./
      return 'I.*'
    when /^I/
      return 'I*.dcm'
    when /.*\.\d{3,4}/
      return '*.[0-9]*'
    when /\.0/
      return '*.0*'
    else
      return nil
    end
    # Note - To exclude just yaml files we could also just use the bash glob
    # '!(*.yaml), but we would have to list all exclusions.  This may turn
    # out easier in the long run.
  end
  
  
  def file_count
    unless @file_count
      if @raw_image_files.first.dicom?
        @file_count = Dir.open(@directory).reject{ |branch| /(^\.|.yaml$)/.match(branch) }.length
      elsif @raw_image_files.first.pfile?
        @file_count = 1
      else raise "File not recognized as dicom or pfile."
      end
    end
    return @file_count
  end
  
  # Creates an Hirb Table for pretty output of dataset info.
  # It takes an array of either RawImageDatasets or RawImageDatasetResources
  def self.to_table(datasets)
    if datasets.first.class.to_s == "RawImageDatasetResource"
      datasets = datasets.map { |ds| ds.to_metamri_image_dataset }
    end
    
    Hirb::Helpers::AutoTable.render(
      datasets.sort_by{ |ds| [ds.timestamp, File.basename(ds.directory)] }, 
      :headers => { :relative_dataset_path => 'Dataset', :series_details => 'Series Details', :file_count => 'File Count'}, 
      :fields => [:relative_dataset_path, :series_details, :file_count],
      :description => false # Turn off rendering row count description at bottom.
    )
      
  end

  # Returns a relative filepath to the dataset.  Handles dicoms by returning the
  # dataset directory, and pfiles by returning either the pfile filename or,
  # if passed a visit directory, the relative path from the visit directory to 
  # the pfile (i.e. P00000.7 or raw/P00000.7).
  def relative_dataset_path(visit_dir = nil)
    image_file = @raw_image_files.first
    case image_file.file_type
      when 'dicom'
        relative_dataset_path = File.basename(directory)
      when 'pfile'
        full_dataset_path = Pathname.new(File.join(directory, image_file.filename))
        if visit_dir
          relative_dataset_path = full_dataset_path.relative_path_from(visit_dir)
        else
          relative_dataset_path = image_file.filename
        end
      else raise "Cannot identify #{@raw_image_files.first.filename}"
    end
    
    return relative_dataset_path
  end
  
  # Reports series details, including description and possilby image quality
  # check comments.  
  def series_details
    @series_description
  end
  
private

  # Gets the earliest timestamp among the raw image files in this dataset.
  def get_earliest_timestamp
    @timestamp = (@raw_image_files.sort_by { |i| i.timestamp }).first.timestamp
  end
  
  # Directory Basename is hardcoded for Pretty Printing using Hirb, which takes symbols as method names for its columns.
  def directory_basename
    File.basename(@directory)
  end

end
#### END OF CLASS ####