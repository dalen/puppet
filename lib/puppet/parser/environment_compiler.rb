require 'puppet/parser/compiler'

class Puppet::Parser::EnvironmentCompiler < Puppet::Parser::Compiler
  def self.compile(env)
    begin
      $env_module_directories = nil
      env.check_for_reparse

      node = Puppet::Node.new(env)
      node.environment = env
      new(node).compile
    rescue => detail
      message = "#{detail} in environment #{env.name}"
      Puppet.log_exception(detail, message)
      raise Puppet::Error, message, detail.backtrace
    end
  end

  def compile
    Puppet.override(@context_overrides, "For compiling environment catalog #{environment.name}") do
      @catalog.environment_instance = environment

      Puppet::Util::Profiler.profile("Env Compile: Created settings scope", [:compiler, :create_settings_scope]) { create_settings_scope }

      activate_binder

      Puppet::Util::Profiler.profile("Env Compile: Evaluated main", [:compiler, :evaluate_main]) { evaluate_main }

      Puppet::Util::Profiler.profile("Env Compile: Evaluated site", [:compiler, :evaluate_site]) { evaluate_site }

      Puppet::Util::Profiler.profile("Env Compile: Evaluated application instances", [:compiler, :evaluate_applications]) { evaluate_applications }

      Puppet::Util::Profiler.profile("Env Compile: Prune", [:compiler, :prune_catalog]) { prune_catalog }

      Puppet::Util::Profiler.profile("Env Compile: Validate Catalog", [:compiler, :validate_site_catalog]) { validate_site_catalog }

      Puppet::Util::Profiler.profile("Env Compile: Finished catalog", [:compiler, :finish_catalog]) { finish }

      fail_on_unevaluated

      if block_given?
        yield @catalog
      else
        @catalog
      end
    end
  end

  # @api private
  def prune_catalog
    prune_env_catalog
  end

  # Prunes the catalog by dropping all resources that are not contained under the Site (if a site expression is used).
  # As a consequence all edges to/from dropped resources are also dropped.
  # Once the pruning is performed, this compiler returns the pruned list when calling the #resources method.
  # The pruning does not alter the order of resources in the resources list.
  #
  def prune_env_catalog
    # Everything under Class[main], that is not under (inclusive of) Site[site] should be pruned as those resources
    # are intended for nodes in a node catalog.
    #
    the_main_class_resource = @catalog.resource('Class', '')
    the_site_resource = @catalog.resource('Site', 'site')

    # Get downstream vertexes returns a hash where the keys are the resources and values nesting level
    rooted_in_main = @catalog.downstream_from_vertex(the_main_class_resource).keys
    if the_site_resource
      keep_from_site = @catalog.downstream_from_vertex(the_site_resource).keys
      keep_from_site << the_site_resource
    end

    to_be_removed = rooted_in_main - keep_from_site
    @catalog.remove_resource(*to_be_removed)
    # The compiler keeps a list of added resources, this shadows that list with the now pruned result
    @pruned_resources = @catalog.resources
  end

  def validate_site_catalog
    the_site_resource = @catalog.resource('Site', 'site')
    return unless the_site_resource

    @catalog.downstream_from_vertex(the_site_resource).keys.each do |r|
      unless r.is_application_component? || r.resource_type.application?
        file = r.file
        line = r.line
        at_part =
        if file && !file.empty? && line
          " at file '#{file}' line #{line}"
        elsif line
          " at line #{line}"
        else
          ''
        end
        raise "Only application components can appear inside a site - #{r} is not allowed#{at_part}"
      end
    end
  end

  def add_resource(scope, resource)
    @resources << resource
    @catalog.add_resource(resource)

    if !resource.class? && resource[:stage]
      raise ArgumentError, "Only classes can set 'stage'; normal resources like #{resource} cannot change run stage"
    end

    # Stages should not be inside of classes.  They are always a
    # top-level container, regardless of where they appear in the
    # manifest.
    return if resource.stage?

    # This adds a resource to the class it lexically appears in in the
    # manifest.
    unless resource.class?
      @catalog.add_edge(scope.resource, resource)
    end
    assert_app_in_site(scope, resource)
  end

  def evaluate_ast_node()
    # Do nothing, the environment catalog is not built for a particular node.
  end

  def on_empty_site
    Puppet.warning("Environment Compiler: Could not find a site definition to evaluate")
  end

  def evaluate_applications
    exceptwrap do
      resources.select { |resource| type = resource.resource_type; type.is_a?(Puppet::Resource::Type) && type.application? }.each do |resource|
        Puppet::Util::Profiler.profile("Evaluated application #{resource}", [:compiler, :evaluate_resource, resource]) do
          resource.evaluate
        end
      end
    end
  end

  # Overrides the regular compiler to be able to return the list of resources after a prune
  # has taken place in the graph representation. Before a prune, the list is the same as in the regular
  # compiler
  #
  def resources
    @pruned_resources || super
  end
end
