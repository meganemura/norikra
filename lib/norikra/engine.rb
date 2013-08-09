require 'java'

require 'norikra/error'

require 'norikra/logger'
include Norikra::Log

require 'esper-4.9.0.jar'
require 'esper/lib/commons-logging-1.1.1.jar'
require 'esper/lib/antlr-runtime-3.2.jar'
require 'esper/lib/cglib-nodep-2.2.jar'

require 'norikra/typedef_manager'

module Norikra
  class Engine
    attr_reader :targets, :queries, :output_pool, :typedef_manager

    def initialize(output_pool, typedef_manager=nil)
      @output_pool = output_pool
      @typedef_manager = typedef_manager || Norikra::TypedefManager.new()

      @service = com.espertech.esper.client.EPServiceProviderManager.getDefaultProvider
      @config = @service.getEPAdministrator.getConfiguration

      @mutex = Mutex.new

      # fieldsets already registered into @runtime
      @registered_fieldsets = {} # {target => {fieldset_summary => Fieldset}

      @targets = []
      @queries = []

      @waiting_queries = []
    end

    def start
      debug "norikra engine starting: creating esper runtime"
      @runtime = @service.getEPRuntime
      debug "norikra engine started"
    end

    def stop
      debug "stopping norikra engine: stop all statements on esper"
      @service.getEPAdministrator.stopAllStatements
      debug "norikra engine stopped"
    end

    def open(target, fields=nil)
      info "opening target", :target => target, :fields => fields
      return false if @targets.include?(target)
      open_target(target, fields)
    end

    def close(target)
      info "closing target", :target => target
      return false unless @targets.include?(target)
      @queries.select{|q| q.targets.include?(target)}.each do |query|
        deregister_query(query)
      end
      close_target(target)
    end

    def reserve(target, field, type)
      @typedef_manager.reserve(target, field, type)
    end

    def register(query)
      info "registering query", :name => query.name, :targets => query.targets, :expression => query.expression
      raise Norikra::ClientError, "query name '#{query.name}' already exists" if @queries.select{|q| q.name == query.name }.size > 0

      query.targets.each do |target|
        open(target) unless @targets.include?(target)
      end
      register_query(query)
    end

    def deregister(query_name)
      info "de-registering query", :name => query_name
      queries = @queries.select{|q| q.name == query_name }
      return nil unless queries.size == 1 # just ignore for 'not found'

      deregister_query(queries.first)
    end

    def send(target, events)
      trace "send messages", :target => target, :events => events
      unless @targets.include?(target) # discard events for target not registered
        trace "messages skipped for non-opened target", :target => target
        return
      end
      return if events.size < 1

      if @typedef_manager.lazy?(target)
        info "opening lazy target", :target => target
        debug "generating base fieldset from event", :target => target, :event => events.first
        base_fieldset = @typedef_manager.generate_base_fieldset(target, events.first)

        debug "registering base fieldset", :target => target, :base => base_fieldset
        register_base_fieldset(target, base_fieldset)

        info "target successfully opened with fieldset", :target => target, :base => base_fieldset
      end

      registered_data_fieldset = @registered_fieldsets[target][:data]

      events.each do |event|
        fieldset = @typedef_manager.refer(target, event)

        unless registered_data_fieldset[fieldset.summary]
          # register waiting queries including this fieldset, and this fieldset itself
          debug "registering unknown fieldset", :target => target, :fieldset => fieldset
          register_fieldset(target, fieldset)
          debug "successfully registered"

          # fieldset should be refined, when waiting_queries rewrite inheritance structure and data fieldset be renewed.
          fieldset = @typedef_manager.refer(target, event)
        end

        trace "calling sendEvent", :target => target, :fieldset => fieldset, :event_type_name => fieldset.event_type_name, :event => event
        @runtime.sendEvent(@typedef_manager.format(target, event).to_java, fieldset.event_type_name)
      end
      nil
    end

    def load(plugin_klass) #TODO: fix api
      load_udf(plugin_klass)
    end

    class Listener
      include com.espertech.esper.client.UpdateListener

      def initialize(query_name, output_pool)
        @query_name = query_name
        @output_pool = output_pool
      end

      def update(new_events, old_events)
        trace "updated event", :query => @query_name, :event => new_events
        @output_pool.push(@query_name, new_events)
      end
    end
    ##### Unmatched events are simply ignored
    # class UnmatchedListener
    #   include com.espertech.esper.client.UnmatchedListener
    #   def update(event)
    #     # puts "unmatched:\n- " + event.getProperties.inspect
    #     # ignore
    #   end
    # end

    private

    def open_target(target, fields)
      @mutex.synchronize do
        return false if @targets.include?(target)

        @typedef_manager.add_target(target, fields)
        @registered_fieldsets[target] = {:base => {}, :query => {}, :data => {}}

        unless @typedef_manager.lazy?(target)
          base_fieldset = @typedef_manager.base_fieldset(target)

          @typedef_manager.bind_fieldset(target, :base, base_fieldset)
          register_fieldset_actually(target, base_fieldset, :base)
        end

        @targets.push(target)
      end
      true
    end

    def close_target(target)
      @mutex.synchronize do
        return false unless @targets.include?(target)

        @typedef_manager.remove_target(target)
        @registered_fieldsets.delete(target)

        @targets.delete(target)
      end
      true
    end

    def register_base_fieldset(target, fieldset)
      # for lazy target, with generated fieldset from sent events.first
      @mutex.synchronize do
        return false unless @typedef_manager.lazy?(target)

        @typedef_manager.activate(target, fieldset)
        register_fieldset_actually(target, fieldset, :base)
      end
      true
    end

    def update_inherits_graph(target, query_fieldset)
      # replace registered data fieldsets with new fieldset inherits this query fieldset
      @typedef_manager.supersets(target, query_fieldset).each do |set|
        rebound = set.rebind(true) # update event_type_name with new inheritations

        register_fieldset_actually(target, rebound, :data, true) # replacing on esper engine
        @typedef_manager.replace_fieldset(target, set, rebound)
        deregister_fieldset_actually(target, set.event_type_name, :data)
      end
    end

    def register_query(query)
      @mutex.synchronize do
        raise Norikra::ClientError, "query '#{query.name}' already exists" unless @queries.select{|q| q.name == query.name }.empty?

        unless @typedef_manager.ready?(query)
          @waiting_queries.push(query)
          @queries.push(query)
          return
        end

        mapping = @typedef_manager.generate_fieldset_mapping(query)
        mapping.each do |target, query_fieldset|
          @typedef_manager.bind_fieldset(target, :query, query_fieldset)
          register_fieldset_actually(target, query_fieldset, :query)
          update_inherits_graph(target, query_fieldset)
          query.fieldsets[target] = query_fieldset
        end

        register_query_actually(query, mapping)
        @queries.push(query)
      end
      true
    end

    def deregister_query(query)
      @mutex.synchronize do
        return nil unless @queries.include?(query)

        deregister_query_actually(query)
        @queries.delete(query)

        if @waiting_queries.include?(query)
          @waiting_queries.delete(query)
        else
          query.fieldsets.each do |target, query_fieldset|
            removed_event_type_name = query_fieldset.event_type_name

            @typedef_manager.unbind_fieldset(target, :query, query_fieldset)
            update_inherits_graph(target, query_fieldset)
            deregister_fieldset_actually(target, removed_event_type_name, :query)
          end
        end
      end
      true
    end

    def register_waiting_queries(target)
      ready = []
      not_ready = []
      @waiting_queries.each do |q|
        if @typedef_manager.ready?(q)
          ready.push(q)
        else
          not_ready.push(q)
        end
      end
      @waiting_queries = not_ready

      ready.each do |query|
        mapping = @typedef_manager.generate_fieldset_mapping(query)
        mapping.each do |target, query_fieldset|
          @typedef_manager.bind_fieldset(target, :query, query_fieldset)
          register_fieldset_actually(target, query_fieldset, :query)
          update_inherits_graph(target, query_fieldset)
          query.fieldsets[target] = query_fieldset
        end
        register_query_actually(query, mapping)
      end
    end

    def register_fieldset(target, fieldset)
      @mutex.synchronize do
        @typedef_manager.bind_fieldset(target, :data, fieldset)

        if @waiting_queries.size > 0
          register_waiting_queries(target)
        end

        register_fieldset_actually(target, fieldset, :data)
      end
    end

    def load_udf(udf_klass)
      load_udf_actually(udf_klass)
    end

    # this method should be protected with @mutex lock
    def register_query_actually(query, mapping)
      # 'mapping' argument is {target => fieldset}
      event_type_name_map = {}
      mapping.keys.each do |key|
        event_type_name_map[key] = mapping[key].event_type_name
      end

      administrator = @service.getEPAdministrator

      statement_model = administrator.compileEPL(query.expression)
      Norikra::Query.rewrite_event_type_name(statement_model, event_type_name_map)

      epl = administrator.create(statement_model)
      epl.java_send :addListener, [com.espertech.esper.client.UpdateListener.java_class], Listener.new(query.name, @output_pool)
      query.statement_name = epl.getName
      # epl is automatically started.
      # epl.isStarted #=> true
    end

    # this method should be protected with @mutex lock
    def deregister_query_actually(query)
      administrator = @service.getEPAdministrator
      epl = administrator.getStatement(query.statement_name)
      return unless epl

      epl.stop unless epl.isStopped
      epl.destroy unless epl.isDestroyed
    end

    # this method should be protected with @mutex lock
    def register_fieldset_actually(target, fieldset, level, replace=false)
      return if level == :data && @registered_fieldsets[target][level][fieldset.summary] && !replace

      # Map Supertype (target) and Subtype (typedef name, like TARGET_TypeDefName)
      # http://esper.codehaus.org/esper-4.9.0/doc/reference/en-US/html/event_representation.html#eventrep-map-supertype
      # epService.getEPAdministrator().getConfiguration()
      #   .addEventType("AccountUpdate", accountUpdateDef, new String[] {"BaseUpdate"});
      case level
      when :base
        debug "add event type", :target => target, :level => 'base', :event_type => fieldset.event_type_name
        @config.addEventType(fieldset.event_type_name, fieldset.definition)
      when :query
        base_name = @typedef_manager.base_fieldset(target).event_type_name
        debug "add event type", :target => target, :level => 'query', :event_type => fieldset.event_type_name, :base => base_name
        @config.addEventType(fieldset.event_type_name, fieldset.definition, [base_name].to_java(:string))
      else
        subset_names = @typedef_manager.subsets(target, fieldset).map(&:event_type_name)
        debug "add event type", :target => target, :level => 'data', :event_type => fieldset.event_type_name, :inherit => subset_names
        @config.addEventType(fieldset.event_type_name, fieldset.definition, subset_names.to_java(:string))

        @registered_fieldsets[target][level][fieldset.summary] = fieldset
      end
      nil
    end

    # this method should be protected with @mutex lock as same as register
    def deregister_fieldset_actually(target, event_type_name, level)
      return if level == :base

      # DON'T check @registered_fieldsets[target][level][fieldset.summary]
      # removed fieldset should be already replaced with register_fieldset_actually w/ replace flag
      debug "remove event type", :target => target, :event_type => event_type_name
      @config.removeEventType(event_type_name, true)
    end

    VALUE_CACHE_ENUM = com.espertech.esper.client.ConfigurationPlugInSingleRowFunction::ValueCache
    FILTER_OPTIMIZABLE_ENUM = com.espertech.esper.client.ConfigurationPlugInSingleRowFunction::FilterOptimizable

    def load_udf_actually(udf_klass)
      debug "importing class into config object", :class => udf_klass.to_s
      udf_klass.init

      className = udf_klass.class_name.to_java(:string)
      functionName = udf_klass.function_name.to_java(:string)
      methodName = udf_klass.method_name.to_java(:string)

      valueCache = udf_klass.value_cache ? VALUE_CACHE_ENUM::ENABLED : VALUE_CACHE_ENUM::DISABLED
      filterOptimizable = udf_klass.filter_optimizable ? FILTER_OPTIMIZABLE_ENUM::ENABLED : FILTER_OPTIMIZABLE_ENUM::DISABLED
      rethrowExceptions = udf_klass.rethrow_exceptions

      debug "adding SingleRowFunction", :class => udf_klass.to_s, :javaClass => udf_klass.class_name
      @config.addPlugInSingleRowFunction(functionName, className, methodName, valueCache, filterOptimizable, rethrowExceptions)
    end
  end
end
