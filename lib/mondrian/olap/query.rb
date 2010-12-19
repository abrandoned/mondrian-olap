module Mondrian
  module OLAP
    class Query
      def self.from(connection, cube_name)
        query = self.new(connection)
        query.cube_name = cube_name
        query
      end

      attr_accessor :cube_name

      def initialize(connection)
        @connection = connection
        @cube = nil
        @axes = []
        @where = []
        @with = []
      end

      # Add new axis(i) to query
      # or return array of axis(i) members if no arguments specified
      def axis(i, *axis_members)
        if axis_members.empty?
          @axes[i]
        else
          @axes[i] ||= []
          @current_set = @axes[i]
          if axis_members.length == 1 && axis_members[0].is_a?(Array)
            @current_set.concat(axis_members[0])
          else
            @current_set.concat(axis_members)
          end
          self
        end
      end

      AXIS_ALIASES = %w(columns rows pages sections chapters)
      AXIS_ALIASES.each_with_index do |axis, i|
        class_eval <<-RUBY, __FILE__, __LINE__ + 1
          def #{axis}(*axis_members)
            axis(#{i}, *axis_members)
          end
        RUBY
      end

      def crossjoin(*axis_members)
        raise ArgumentError, "cannot use crossjoin method before axis or with_set method" unless @current_set
        raise ArgumentError, "specify list of members for crossjoin method" if axis_members.empty?
        members = axis_members.length == 1 && axis_members[0].is_a?(Array) ? axis_members[0] : axis_members
        @current_set.replace [:crossjoin, @current_set.clone, members]
        self
      end

      def except(*axis_members)
        raise ArgumentError, "cannot use except method before axis or with_set method" unless @current_set
        raise ArgumentError, "specify list of members for except method" if axis_members.empty?
        members = axis_members.length == 1 && axis_members[0].is_a?(Array) ? axis_members[0] : axis_members
        if @current_set[0] == :crossjoin
          @current_set[2] = [:except, @current_set[2], members]
        else
          @current_set.replace [:except, @current_set.clone, members]
        end
        self
      end

      def nonempty
        raise ArgumentError, "cannot use nonempty method before axis or with_set method" unless @current_set
        @current_set.replace [:nonempty, @current_set.clone]
        self
      end

      VALID_ORDERS = ['ASC', 'BASC', 'DESC', 'BDESC']

      def order(expression, direction)
        raise ArgumentError, "cannot use order method before axis or with_set method" unless @current_set
        direction = direction.to_s.upcase
        raise ArgumentError, "invalid order direction #{direction.inspect}," <<
          " should be one of #{VALID_ORDERS.inspect[1..-2]}" unless VALID_ORDERS.include?(direction)
        @current_set.replace [:order, @current_set.clone, expression, direction]
        self
      end

      def hierarchize(order=nil, all=nil)
        raise ArgumentError, "cannot use hierarchize method before axis or with_set method" unless @current_set
        order = order && order.to_s.upcase
        raise ArgumentError, "invalid hierarchize order #{order.inspect}" unless order.nil? || order == 'POST'
        if all.nil? && @current_set[0] == :crossjoin
          @current_set[2] = [:hierarchize, @current_set[2]]
          @current_set[2] << order if order
        else
          @current_set.replace [:hierarchize, @current_set.clone]
          @current_set << order if order
        end
        self
      end

      def hierarchize_all(order=nil)
        hierarchize(order, :all)
      end

      # Add new WHERE condition to query
      # or return array of existing conditions if no arguments specified
      def where(*members)
        if members.empty?
          @where
        else
          if members.length == 1 && members[0].is_a?(Array)
            @where.concat(members[0])
          else
            @where.concat(members)
          end
          self
        end
      end

      # Add definition of calculated member
      def with_member(member_name)
        @with << [:member, member_name]
        @current_set = nil
        self
      end

      # Add definition of named_set
      def with_set(set_name)
        @current_set = []
        @with << [:set, set_name, @current_set]
        self
      end

      # return array of member and set definitions
      def with
        @with
      end

      # Add definition to calculated member or to named set
      def as(*params)
        # definition of named set
        if @current_set
          if params.empty?
            raise ArgumentError, "named set cannot be empty"
          else
            raise ArgumentError, "cannot use 'as' method before with_set method" unless @current_set.empty?
            if params.length == 1 && params[0].is_a?(Array)
              @current_set.concat(params[0])
            else
              @current_set.concat(params)
            end
          end
        # definition of calculated member
        else
          member_definition = @with.last
          options = params.last.is_a?(Hash) ? params.pop : nil
          raise ArgumentError, "cannot use 'as' method before with_member method" unless member_definition &&
            member_definition[0] == :member && member_definition.length == 2
          raise ArgumentError, "calculated member definition should be single expression" unless params.length == 1
          member_definition << params[0]
          member_definition << options if options
        end
        self
      end

      def to_mdx
        mdx = ""
        mdx << "WITH #{with_to_mdx}\n" unless @with.empty?
        mdx << "SELECT #{axis_to_mdx}\n"
        mdx << "FROM #{from_to_mdx}"
        mdx << "\nWHERE #{where_to_mdx}" unless @where.empty?
        mdx
      end

      def execute
        @connection.execute to_mdx
      end

      private

      # FIXME: keep original order of WITH MEMBER and WITH SET defitions
      def with_to_mdx
        @with.map do |definition|
          case definition[0]
          when :member
            member_name = definition[1]
            expression = definition[2]
            options = definition[3]
            options_string = ''
            options.each do |option, value|
              options_string << ", #{option.to_s.upcase} = #{quote_value(value)}"
            end
            "MEMBER #{member_name} AS #{quote_value(expression)}#{options_string}"
          when :set
            set_name = definition[1]
            set_members = definition[2]
            "SET #{set_name} AS #{quote_value(members_to_mdx(set_members))}"
          end
        end.join("\n")
      end

      def axis_to_mdx
        mdx = ""
        @axes.each_with_index do |axis_members, i|
          axis_name = AXIS_ALIASES[i] ? AXIS_ALIASES[i].upcase : "AXIS(#{i})"
          mdx << ",\n" if i > 0
          mdx << members_to_mdx(axis_members) << " ON " << axis_name
        end
        mdx
      end

      def members_to_mdx(axis_members)
        if axis_members.length == 1
          axis_members[0]
        elsif axis_members[0].is_a?(Symbol)
          case axis_members[0]
          when :crossjoin
            "CROSSJOIN(#{members_to_mdx(axis_members[1])}, #{members_to_mdx(axis_members[2])})"
          when :except
            "EXCEPT(#{members_to_mdx(axis_members[1])}, #{members_to_mdx(axis_members[2])})"
          when :nonempty
            "NON EMPTY #{members_to_mdx(axis_members[1])}"
          when :order
            expression = axis_members[2].is_a?(Array) ? "(#{axis_members[2].join(', ')})" : axis_members[2]
            "ORDER(#{members_to_mdx(axis_members[1])}, #{expression}, #{axis_members[3]})"
          when :hierarchize
            "HIERARCHIZE(#{members_to_mdx(axis_members[1])}#{axis_members[2] && ", #{axis_members[2]}"})"
          else
            raise ArgumentError, "Cannot generate MDX for invalid set operation #{axis_members[0].inspect}"
          end
        else
          "{#{axis_members.join(', ')}}"
        end
      end

      def from_to_mdx
        "[#{@cube_name}]"
      end

      def where_to_mdx
        mdx = '('
        mdx << @where.map do |condition|
          condition
        end.join(', ')
        mdx << ')'
      end

      def quote_value(value)
        case value
        when String
          "'#{value.gsub("'", "''")}'"
        when TrueClass, FalseClass
          value ? 'TRUE' : 'FALSE'
        when NilClass
          'NULL'
        else
          "#{value}"
        end
      end
    end
  end
end