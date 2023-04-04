# frozen_string_literal: true

# Stores a generated report.
class ReportBlob < ActiveStorage::Blob
  def self.create_for_upload_later!
    # ActiveStorage discourages modifying a blob later but we need a blob
    # before we know anything about the report file. It enables us to use the
    # same blob in the controller to read the result.
    create_before_direct_upload!(
      filename: "tbd",
      byte_size: 0,
      checksum: "0",
      content_type: "application/octet-stream",
    ).tap do |blob|
      ActiveStorage::PurgeJob.set(wait: 1.month).perform_later(blob)
    end
  end

  def store(content)
    io = StringIO.new(content)
    upload(io, identify: false)
    save!
  end

  def content_stored?
    @content_stored ||= reload.checksum != "0"
  end

  def result
    @result ||= download
  end
end
