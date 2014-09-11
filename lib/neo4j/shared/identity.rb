module Neo4j::Shared
  module Identity
    def ==(o)
      o.class == self.class && o.id == id
    end
    alias_method :eql?, :==

    # Returns an Enumerable of all (primary) key attributes
    # or nil if model.persisted? is false
    def to_key
      persisted? ? [id] : nil
    end

    # @return [Fixnum, nil] the neo4j id of the node if persisted or nil
    def neo_id
      _persisted_obj ? _persisted_obj.neo_id : nil
    end

    def id
      if self.class.respond_to?(:id_property_name) # ActiveNode
        read_attribute(self.class.id_property_name)
      else # ActiveRel
        id = neo_id
        id.is_a?(Integer) ? id : nil
      end
    end

    def hash
      id.hash
    end
  end
end
