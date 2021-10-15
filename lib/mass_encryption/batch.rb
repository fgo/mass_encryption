class MassEncryption::Batch
  attr_reader :from_id, :size, :page

  DEFAULT_BATCH_SIZE = 1000

  class << self
    def first_for(klass, size: DEFAULT_BATCH_SIZE, page: 0)
      MassEncryption::Batch.new(klass: klass, from_id: klass.first.id, size: size, page: page) if klass.first
    end
  end

  def initialize(klass:, from_id:, size: DEFAULT_BATCH_SIZE, page: 0)
    @class_name = klass.name # not storing class as instance variable as it causes stack overflow error with json serialization
    @from_id = from_id
    @size = size
    @page = page
  end

  def klass
    @class_name.constantize
  end

  def encrypt_now
    if klass.encrypted_attributes.present?
      klass.upsert_all record_attributes_to_upsert, on_duplicate: Arel.sql(encrypted_attributes_assignments_sql)
    end
  end

  def encrypt_later(auto_enqueue_next: false)
    MassEncryption::BatchEncryptionJob.perform_later(self, auto_enqueue_next: auto_enqueue_next)
  end

  def present?
    records.present? # we do want to load the association to avoid 2 queries
  end

  def next
    self.class.new(klass: klass, from_id: records.last.id + 1, size: size, page: page)
  end

  private
    def record_attributes_to_upsert
      records.collect do |record|
        record.attributes.slice(*attribute_names_to_upsert)
      end
    end

    def attribute_names_to_upsert
      @attribute_names_to_upsert ||= klass.encrypted_attributes.to_a.collect(&:to_s).including(klass.primary_key)
    end

    def encrypted_attributes_assignments_sql
      klass.encrypted_attributes.collect do |name|
        "`#{name}`=VALUES(`#{name}`)"
      end.join(", ")
    end

    def records
      @records ||= klass.where("id >= ?", determine_from_id).order(id: :asc).limit(size)
    end

    def determine_from_id
      if page == 0
        from_id # save a query to determine the id for the first page
      else
        ids_in_the_same_track.last || from_id
      end
    end

    def offset
      page * size
    end

    def ids_in_the_same_track
      klass.where("id >= ?", from_id).order(id: :asc).limit(offset).ids
    end
end
