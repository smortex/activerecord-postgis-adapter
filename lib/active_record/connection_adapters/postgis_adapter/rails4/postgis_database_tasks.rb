module ActiveRecord  # :nodoc:
  module ConnectionAdapters  # :nodoc:
    module PostGISAdapter  # :nodoc:
      class PostGISDatabaseTasks < ::ActiveRecord::Tasks::PostgreSQLDatabaseTasks  # :nodoc:

        def initialize(config)
          super
          ensure_installation_configs
        end

        def setup_gis
          establish_su_connection
          setup_gis_schemas
          if script_dir
            setup_gis_from_script_dir
          elsif extension_names
            setup_gis_from_extension
          end
          if has_su? && (script_dir || extension_names)
            setup_gis_grant_privileges
          end
          establish_connection(configuration)
        end

        # Overridden to set the database owner and call setup_gis
        def create(master_established = false)
          establish_master_connection unless master_established
          extra_configs = {'encoding' => encoding}
          extra_configs['owner'] = username if has_su?
          connection.create_database(configuration['database'], configuration.merge(extra_configs))
          setup_gis
        rescue ::ActiveRecord::StatementInvalid => error
          if /database .* already exists/ === error.message
            raise ::ActiveRecord::Tasks::DatabaseAlreadyExists
          else
            raise
          end
        end

        # Overridden to remove postgis schema
        def structure_dump(filename)
          set_psql_env
          _search_path = search_path.dup
          _search_path.delete('postgis')
          _search_path = ['public'] if _search_path.length == 0
          search_path_clause_ = _search_path.map{ |part_| "--schema=#{::Shellwords.escape(part_)}" }.join(' ')
          command = "pg_dump -i -s -x -O -f #{::Shellwords.escape(filename)} #{search_path_clause_} #{::Shellwords.escape(configuration['database'])}"
          raise 'Error dumping database' unless ::Kernel.system(command)
          ::File.open(filename, "a") { |f_| f_ << "SET search_path TO #{ActiveRecord::Base.connection.schema_search_path};\n\n" }
        end

        private

        # Overridden to use su_username and su_password
        def establish_master_connection
          establish_connection(configuration.merge(
            'database' => 'postgres',
            'schema_search_path' => 'public',
            'username' => su_username,
            'password' => su_password))
        end

        def establish_su_connection
          establish_connection(configuration.merge(
            'schema_search_path' => 'public',
            'username' => su_username,
            'password' => su_password))
        end

        def username
          @username ||= configuration['username']
        end

        def quoted_username
          @quoted_username ||= ::ActiveRecord::Base.connection.quote_column_name(username)
        end

        def password
          @password ||= configuration['password']
        end

        def su_username
          @su_username ||= configuration['su_username'] || username
        end

        def su_password
          @su_password ||= configuration['su_password'] || password
        end

        def has_su?
          @has_su = configuration.include?('su_username') unless defined?(@has_su)
          @has_su
        end

        def search_path
          @search_path ||= configuration['schema_search_path'].to_s.strip.split(',').map(&:strip)
        end

        def postgis_schema
          @postgis_schema ||= search_path.include?('postgis') ? 'postgis' : (search_path.last || 'public')
        end

        def script_dir
          @script_dir = configuration['script_dir'] unless defined?(@script_dir)
          @script_dir
        end

        def extension_names
          @extension_names ||= begin
            ext_ = configuration['postgis_extension']
            case ext_
            when ::String
              ext_.split(',')
            when ::Array
              ext_
            else
              ['postgis']
            end
          end
        end

        def ensure_installation_configs
          if configuration['setup'] == 'default' && !configuration['script_dir'] && !configuration['postgis_extension']
            share_dir_ = `pg_config --sharedir`.strip rescue '/usr/share'
            script_dir_ = ::File.expand_path('contrib/postgis-1.5', share_dir_)
            control_file_ = ::File.expand_path('extension/postgis.control', share_dir_)
            if ::File.readable?(control_file_)
              configuration['postgis_extension'] = 'postgis'
            elsif ::File.directory?(script_dir_)
              configuration['script_dir'] = script_dir_
            end
          end
        end

        def setup_gis_schemas
          auth_ = has_su? ? " AUTHORIZATION #{quoted_username}" : ''
          search_path.each do |schema_|
            if schema_.downcase != 'public' && !connection.execute("SELECT 1 FROM pg_catalog.pg_namespace WHERE nspname='#{schema_}'").try(:first)
              connection.execute("CREATE SCHEMA #{schema_}#{auth_}")
            end
          end
        end

        def setup_gis_from_extension
          extension_names.each do |extname|
            if extname == 'postgis_topology'
              raise ::ArgumentError, "'topology' must be in schema_search_path for postgis_topology" unless search_path.include?('topology')
              connection.execute("CREATE EXTENSION IF NOT EXISTS #{extname} SCHEMA topology")
            else
              connection.execute("CREATE EXTENSION IF NOT EXISTS #{extname} SCHEMA #{postgis_schema}")
            end
          end
        end

        def setup_gis_from_script_dir
          connection.execute("SET search_path TO #{postgis_schema}")
          connection.execute("CREATE OR REPLACE LANGUAGE plpgsql")
          connection.execute(::File.read(::File.expand_path('postgis.sql', script_dir)))
          connection.execute(::File.read(::File.expand_path('spatial_ref_sys.sql', script_dir)))
        end

        def setup_gis_grant_privileges
          connection.execute("GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA #{postgis_schema} TO #{quoted_username}")
          connection.execute("GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA #{postgis_schema} TO #{quoted_username}")
          postgis_version_ = connection.execute( "SELECT #{postgis_schema}.postgis_version();" ).first['postgis_version']
          if postgis_version_ =~ /^2/
            connection.execute("ALTER VIEW #{postgis_schema}.geometry_columns OWNER TO #{quoted_username}")
            connection.execute("ALTER VIEW #{postgis_schema}.geography_columns OWNER TO #{quoted_username}")
          else
            connection.execute("ALTER TABLE #{postgis_schema}.geometry_columns OWNER TO #{quoted_username}")
          end
          connection.execute("ALTER TABLE #{postgis_schema}.spatial_ref_sys OWNER TO #{quoted_username}")
        end

      end

      ::ActiveRecord::Tasks::DatabaseTasks.register_task(/postgis/, PostGISDatabaseTasks)

    end
  end
end
