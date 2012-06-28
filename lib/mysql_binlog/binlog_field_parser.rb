module MysqlBinlog
  # All MySQL types mapping to their integer values.
  MYSQL_TYPES_HASH = {
    :decimal         => 0,
    :tiny            => 1,
    :short           => 2,
    :long            => 3,
    :float           => 4,
    :double          => 5,
    :null            => 6,
    :timestamp       => 7,
    :longlong        => 8,
    :int24           => 9,
    :date            => 10,
    :time            => 11,
    :datetime        => 12,
    :year            => 13,
    :newdate         => 14,
    :varchar         => 15,
    :bit             => 16,
    :newdecimal      => 246,
    :enum            => 247,
    :set             => 248,
    :tiny_blob       => 249,
    :medium_blob     => 250,
    :long_blob       => 251,
    :blob            => 252,
    :var_string      => 253,
    :string          => 254,
    :geometry        => 255,
  }

  # All MySQL types in a simple lookup array to map an integer to its symbol.
  MYSQL_TYPES = MYSQL_TYPES_HASH.inject(Array.new(256)) do |type_array, item|
   type_array[item[1]] = item[0]
   type_array
  end

  class BinlogFieldParser
    attr_accessor :binlog
    attr_accessor :reader

    def initialize(binlog_instance)
      @format_cache = {}
      @binlog = binlog_instance
      @reader = binlog_instance.reader
    end

    # Read an unsigned 8-bit (1-byte) integer.
    def read_uint8
      reader.read(1).unpack("C").first
    end

    # Read an unsigned 16-bit (2-byte) integer.
    def read_uint16
      reader.read(2).unpack("v").first
    end

    # Read an unsigned 24-bit (3-byte) integer.
    def read_uint24
      a, b, c = reader.read(3).unpack("CCC")
      a + (b << 8) + (c << 16)
    end

    # Read an unsigned 32-bit (4-byte) integer.
    def read_uint32
      reader.read(4).unpack("V").first
    end

    # Read an unsigned 48-bit (6-byte) integer.
    def read_uint48
      a, b, c = reader.read(6).unpack("vvv")
      a + (b << 16) + (c << 32)
    end

    # Read an unsigned 64-bit (8-byte) integer.
    def read_uint64
      reader.read(8).unpack("Q").first
    end

    # Read a single-precision (4-byte) floating point number.
    def read_float
      reader.read(4).unpack("g").first
    end

    # Read a double-precision (8-byte) floating point number.
    def read_double
      reader.read(8).unpack("G").first
    end

    # Read a variable-length "Length Coded Binary" integer. This is derived
    # from the MySQL protocol, and re-used in the binary log format. This
    # format uses the first byte to alternately store the actual value for
    # integer values <= 250, or to encode the number of following bytes
    # used to store the actual value, which can be 2, 3, or 8. It also
    # includes support for SQL NULL as a special case.
    #
    # See: http://forge.mysql.com/wiki/MySQL_Internals_ClientServer_Protocol#Elements
    def read_varint
      first_byte = read_uint8

      case
      when first_byte <= 250
        first_byte
      when first_byte == 251
        nil
      when first_byte == 252
        read_uint16
      when first_byte == 253
        read_uint24
      when first_byte == 254
        read_uint64
      when first_byte == 255
        raise "Invalid variable-length integer"
      end
    end

    # Read a non-terminated string, provided its length.
    def read_nstring(length)
      reader.read(length)
    end

    # Read a null-terminated string, provided its length (without the null).
    def read_nstringz(length)
      string = read_nstring(length)
      reader.read(1) # null
      string
    end

    # Read a (Pascal-style) length-prefixed string. The length is stored as a
    # 8-bit (1-byte) to 32-bit (4-byte) unsigned integer, depending on the
    # optional size parameter (default 1), followed by the string itself with
    # no termination character.
    def read_lpstring(size=1)
      case size
      when 1
        length = read_uint8
      when 2
        length = read_uint16
      when 3
        length = read_uint24
      when 4
        length = read_uint32
      end
      read_nstring(length)
    end

    # Read an lpstring (as above) which is also terminated with a null byte.
    def read_lpstringz(size=1)
      string = read_lpstring(size)
      reader.read(1) # null
      string
    end

    # Read a MySQL-style varint length-prefixed string. The length is stored
    # as a variable-length "Length Coded Binary" value (see read_varint) which
    # is followed by the string content itself. No termination is included.
    def read_varstring
      length = read_varint
      read_nstring(length)
    end

    # Read an array of unsigned 8-bit (1-byte) integers.
    def read_uint8_array(length)
      reader.read(length).bytes.to_a
    end

    # Read an arbitrary-length bitmap, provided its length. Returns an array
    # of true/false values.
    def read_bit_array(length)
      data = reader.read((length+7)/8)
      data.unpack("b*").first.bytes.to_a.map { |i| (i-48) == 1 }.shift(length)
    end

    # Read a uint32 value, and convert it to an array of symbols derived
    # from a mapping table provided.
    def read_uint32_bitmap_by_name(names)
      value = read_uint32
      names.inject([]) do |result, (name, bit_value)|
        if (value & bit_value) != 0
          result << name
        end
        result
      end
    end

    # Read a series of fields, provided an array of field descriptions. This
    # can be used to read many types of fixed-length structures.
    def read_and_unpack(format_description)
      @format_cache[format_description] ||= {}
      this_format = @format_cache[format_description][:format] ||= 
        format_description.inject("") { |o, f| o+(f[:format] || "") }
      this_length = @format_cache[format_description][:length] ||=
        format_description.inject(0)  { |o, f| o+(f[:length] || 0) }

      fields = {}

      fields_array = reader.read(this_length).unpack(this_format)
      format_description.each_with_index do |field, index| 
        fields[field[:name]] = fields_array[index]
      end

      fields
    end

    def read_mysql_type_metadata(column_type)
      case column_type
      when :float, :double
        { :size => read_uint8 }
      when :varchar
        { :max_length => read_uint16 }
      when :bit
        { :size => read_uint8 }
      when :decimal
        {
          :precision => read_uint8,
          :decimals  => read_uint8,
        }
      when :blob
        { :length_size => read_uint8 }
      when :string, :var_string
        {
          :real_type   => read_uint8,
          :max_length  => read_uint8,
        }
      when :geometry
        { :length_size => read_uint8 }
      end
    end

    # Read a single field, provided the MySQL column type as a symbol. Not all
    # types are currently supported.
    def read_mysql_type(type, metadata=nil)
      case type
      when :tiny
        read_uint8
      when :short
        read_uint16
      when :int24
        read_uint24
      when :long
        read_uint32
      when :longlong
        read_uint64
      when :float
        read_float
      when :double
        read_double
      when :string, :var_string
        read_varstring
      when :varchar
        read_lpstring(2)
      when :blob
        read_lpstring(metadata[:length_size])
      when :timestamp
        read_uint32
      when :year
        read_uint8 + 1900
      #when :date
      #when :time
      #when :datetime
      #when :newdate
      #when :bit
      #when :decimal
      #when :newdecimal
      #when :enum
      #when :set
      #when :geometry
      end
    end

  end
end