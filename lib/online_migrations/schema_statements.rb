# frozen_string_literal: true

module OnlineMigrations
  module SchemaStatements
    # Updates the value of a column in batches.
    #
    # @param table_name [String, Symbol]
    # @param column_name [String, Symbol]
    # @param value value for the column. It is typically a literal. To perform a computed
    #     update, an Arel literal can be used instead
    # @option options [Integer] :batch_size (1000) size of the batch
    # @option options [String, Symbol] :batch_column_name (primary key) option is for tables without primary key, in this
    #     case another unique integer column can be used. Example: `:user_id`
    # @option options [Proc, Boolean] :progress (false) whether to show progress while running.
    #   - when `true` - will show progress (prints "." for each batch)
    #   - when `false` - will not show progress
    #   - when `Proc` - will call the proc on each iteration with the batched relation as argument.
    #     Example: `proc { |_relation| print "." }`
    # @option options [Integer] :pause_ms (50) The number of milliseconds to sleep between each batch execution.
    #     This helps to reduce database pressure while running updates and gives time to do maintenance tasks
    #
    # @yield [relation] a block to be called to add extra conditions to the queries being executed
    # @yieldparam relation [ActiveRecord::Relation] an instance of `ActiveRecord::Relation`
    #     to add extra conditions to
    #
    # @return [void]
    #
    # @example
    #   update_column_in_batches(:users, :admin, false)
    #
    # @example With extra conditions
    #   update_column_in_batches(:users, :name, "Guest") do |relation|
    #     relation.where(name: nil)
    #   end
    #
    # @example From other column
    #   update_column_in_batches(:users, :name_for_type_change, Arel.sql("name"))
    #
    # @example With computed value
    #   truncated_name = Arel.sql("substring(name from 1 for 64)")
    #   update_column_in_batches(:users, :name, truncated_name) do |relation|
    #     relation.where("length(name) > 64")
    #   end
    #
    # @note This method should not be run within a transaction
    # @note Consider `update_columns_in_batches` when updating multiple columns
    #   to avoid rewriting the table multiple times.
    #
    def update_column_in_batches(table_name, column_name, value, **options, &block)
      update_columns_in_batches(table_name, [[column_name, value]], **options, &block)
    end

    # Same as `update_column_in_batches`, but for multiple columns.
    #
    # This is useful to avoid multiple costly disk rewrites of large tables
    # when updating each column separately.
    #
    # @param columns_and_values
    # columns_and_values is an array of arrays (first item is a column name, second - new value)
    #
    # @see #update_column_in_batches
    #
    def update_columns_in_batches(table_name, columns_and_values,
                                  batch_size: 1000, batch_column_name: primary_key(table_name), progress: false, pause_ms: 50)
      __ensure_not_in_transaction!

      if !columns_and_values.is_a?(Array) || !columns_and_values.all? { |e| e.is_a?(Array) }
        raise ArgumentError, "columns_and_values must be an array of arrays"
      end

      if progress
        if progress == true
          progress = ->(_) { print(".") }
        elsif !progress.respond_to?(:call)
          raise ArgumentError, "The progress body needs to be a callable."
        end
      end

      model = Utils.define_model(self, table_name)

      conditions = columns_and_values.map do |(column_name, value)|
        arel_column = model.arel_table[column_name]
        arel_column.not_eq(value).or(arel_column.eq(nil))
      end

      batch_relation = model.where(conditions.inject(:and))
      batch_relation = yield batch_relation if block_given?

      iterator = BatchIterator.new(batch_relation)
      iterator.each_batch(of: batch_size, column: batch_column_name) do |relation|
        updates = columns_and_values.to_h

        relation.update_all(updates)

        progress.call(relation) if progress

        sleep(pause_ms * 0.001) if pause_ms > 0
      end
    end

    # Renames a column without requiring downtime
    #
    # The technique is built on top of database views, using the following steps:
    #   1. Rename the table to some temporary name
    #   2. Create a VIEW using the old table name with addition of a new column as an alias of the old one
    #   3. Add a workaround for ActiveRecord's schema cache
    #
    # For example, to rename `name` column to `first_name` of the `users` table, we can run:
    #
    #     BEGIN;
    #     ALTER TABLE users RENAME TO users_column_rename;
    #     CREATE VIEW users AS SELECT *, first_name AS name FROM users;
    #     COMMIT;
    #
    # As database views do not expose the underlying table schema (default values, not null constraints,
    # indexes, etc), further steps are needed to update the application to use the new table name.
    # ActiveRecord heavily relies on this data, for example, to initialize new models.
    #
    # To work around this limitation, we need to tell ActiveRecord to acquire this information
    # from original table using the new table name (see notes).
    #
    # @param table_name [String, Symbol] table name
    # @param column_name [String, Symbol] the name of the column to be renamed
    # @param new_column_name [String, Symbol] new new name of the column
    #
    # @return [void]
    #
    # @example
    #   initialize_column_rename(:users, :name, :first_name)
    #
    # @note
    #   Prior to using this method, you need to register the database table so that
    #   it instructs ActiveRecord to fetch the database table information (for SchemaCache)
    #   using the original table name (if it's present). Otherwise, fall back to the old table name:
    #
    #   ```OnlineMigrations.config.column_renames[table_name] = { old_column_name => new_column_name }```
    #
    #   Deploy this change before proceeding with this helper.
    #   This is necessary to avoid errors during a zero-downtime deployment.
    #
    # @note None of the DDL operations involving original table name can be performed
    #   until `finalize_column_rename` is run
    #
    def initialize_column_rename(table_name, column_name, new_column_name)
      tmp_table = "#{table_name}_column_rename"

      transaction do
        rename_table(table_name, tmp_table)
        execute("CREATE VIEW #{table_name} AS SELECT *, #{column_name} AS #{new_column_name} FROM #{tmp_table}")
      end
    end

    # Reverts operations performed by initialize_column_rename
    #
    # @param table_name [String, Symbol] table name
    # @param _column_name [String, Symbol] the name of the column to be renamed.
    #     Passing this argument will make this change reversible in migration
    # @param _new_column_name [String, Symbol] new new name of the column.
    #     Passing this argument will make this change reversible in migration
    #
    # @return [void]
    #
    # @example
    #   revert_initialize_column_rename(:users, :name, :first_name)
    #
    def revert_initialize_column_rename(table_name, _column_name = nil, _new_column_name = nil)
      transaction do
        execute("DROP VIEW #{table_name}")
        rename_table("#{table_name}_column_rename", table_name)
      end
    end

    # Finishes the process of column rename
    #
    # @param (see #initialize_column_rename)
    # @return [void]
    #
    # @example
    #   finalize_column_rename(:users, :name, :first_name)
    #
    def finalize_column_rename(table_name, column_name, new_column_name)
      transaction do
        execute("DROP VIEW #{table_name}")
        rename_table("#{table_name}_column_rename", table_name)
        rename_column(table_name, column_name, new_column_name)
      end
    end

    # Reverts operations performed by finalize_column_rename
    #
    # @param (see #initialize_column_rename)
    # @return [void]
    #
    # @example
    #   revert_finalize_column_rename(:users, :name, :first_name)
    #
    def revert_finalize_column_rename(table_name, column_name, new_column_name)
      tmp_table = "#{table_name}_column_rename"

      transaction do
        rename_column(table_name, new_column_name, column_name)
        rename_table(table_name, tmp_table)
        execute("CREATE VIEW #{table_name} AS SELECT *, #{column_name} AS #{new_column_name} FROM #{tmp_table}")
      end
    end

    # Renames a table without requiring downtime
    #
    # The technique is built on top of database views, using the following steps:
    #   1. Rename the database table
    #   2. Create a database view using the old table name by pointing to the new table name
    #   3. Add a workaround for ActiveRecord's schema cache
    #
    # For example, to rename `clients` table name to `users`, we can run:
    #
    #     BEGIN;
    #     ALTER TABLE clients RENAME TO users;
    #     CREATE VIEW clients AS SELECT * FROM users;
    #     COMMIT;
    #
    # As database views do not expose the underlying table schema (default values, not null constraints,
    # indexes, etc), further steps are needed to update the application to use the new table name.
    # ActiveRecord heavily relies on this data, for example, to initialize new models.
    #
    # To work around this limitation, we need to tell ActiveRecord to acquire this information
    # from original table using the new table name (see notes).
    #
    # @param table_name [String, Symbol]
    # @param new_name [String, Symbol] table's new name
    #
    # @return [void]
    #
    # @example
    #   initialize_table_rename(:clients, :users)
    #
    # @note
    #   Prior to using this method, you need to register the database table so that
    #   it instructs ActiveRecord to fetch the database table information (for SchemaCache)
    #   using the new table name (if it's present). Otherwise, fall back to the old table name:
    #
    #   ```
    #     OnlineMigrations.config.table_renames[old_table_name] = new_table_name
    #   ```
    #
    #   Deploy this change before proceeding with this helper.
    #   This is necessary to avoid errors during a zero-downtime deployment.
    #
    # @note None of the DDL operations involving original table name can be performed
    #   until `finalize_table_rename` is run
    #
    def initialize_table_rename(table_name, new_name)
      transaction do
        rename_table(table_name, new_name)
        execute("CREATE VIEW #{table_name} AS SELECT * FROM #{new_name}")
      end
    end

    # Reverts operations performed by initialize_table_rename
    #
    # @param (see #initialize_table_rename)
    # @return [void]
    #
    # @example
    #   revert_initialize_table_rename(:clients, :users)
    #
    def revert_initialize_table_rename(table_name, new_name)
      transaction do
        execute("DROP VIEW IF EXISTS #{table_name}")
        rename_table(new_name, table_name)
      end
    end

    # Finishes the process of table rename
    #
    # @param table_name [String, Symbol]
    # @param _new_name [String, Symbol] table's new name. Passing this argument will make
    #   this change reversible in migration
    # @return [void]
    #
    # @example
    #   finalize_table_rename(:users, :clients)
    #
    def finalize_table_rename(table_name, _new_name = nil)
      execute("DROP VIEW IF EXISTS #{table_name}")
    end

    # Reverts operations performed by finalize_table_rename
    #
    # @param table_name [String, Symbol]
    # @param new_name [String, Symbol] table's new name
    # @return [void]
    #
    # @example
    #   revert_finalize_table_rename(:users, :clients)
    #
    def revert_finalize_table_rename(table_name, new_name)
      execute("CREATE VIEW #{table_name} AS SELECT * FROM #{new_name}")
    end

    # Adds a column with a default value without durable locks of the entire table
    #
    # This method runs the following steps:
    #
    # 1. Add the column allowing NULLs
    # 2. Change the default value of the column to the specified value
    # 3. Backfill all existing rows in batches
    # 4. Set a `NOT NULL` constraint on the column if desired (the default).
    #
    # These steps ensure a column can be added to a large and commonly used table
    # without locking the entire table for the duration of the table modification.
    #
    # For extra large tables (100s of millions of records) you may consider implementing
    #   the steps from this helper method yourself as a separate migrations, replacing step #3
    #   with the help of background migrations (see `backfill_column_in_background`).
    #
    # @param table_name [String, Symbol]
    # @param column_name [String, Symbol]
    # @param type [Symbol] type of new column
    #
    # @param options [Hash] `:batch_size`, `:batch_column_name`, `:progress`, and `:pause_ms`
    #     are directly passed to `update_column_in_batches` to control the backfilling process.
    #     Additional options (like `:limit`, etc) are forwarded to `add_column`
    # @option options :default The column's default value
    # @option options [Boolean] :null (true) Allows or disallows NULL values in the column
    #
    # @return [void]
    #
    # @example
    #   add_column_with_default(:users, :admin, :boolean, default: false, null: false)
    #
    # @example Additional column options
    #   add_column_with_default(:users, :twitter, :string, default: "", limit: 64)
    #
    # @example Additional batching options
    #   add_column_with_default(:users, :admin, :boolean, default: false,
    #                           batch_size: 10_000, pause_ms: 100)
    #
    # @note This method should not be run within a transaction
    # @note For PostgreSQL 11+ you can use `add_column` instead
    #
    def add_column_with_default(table_name, column_name, type, **options)
      default = options.fetch(:default)
      if default.is_a?(Proc) &&
         ActiveRecord.version < Gem::Version.new("5.0.0.beta2") # https://github.com/rails/rails/pull/20005
        raise ArgumentError, "Expressions as default are not supported"
      end

      if @connection.server_version >= 11_00_00 && !Utils.volatile_default?(self, type, default)
        add_column(table_name, column_name, type, **options)
      else
        __ensure_not_in_transaction!

        batch_options = options.extract!(:batch_size, :batch_column_name, :progress, :pause_ms)

        if column_exists?(table_name, column_name)
          Utils.say("Column was not created because it already exists (this may be due to an aborted migration "\
            "or similar) table_name: #{table_name}, column_name: #{column_name}")
        else
          transaction do
            add_column(table_name, column_name, type, **options.merge(default: nil, null: true))
            change_column_default(table_name, column_name, default)
          end
        end

        update_column_in_batches(table_name, column_name, default, **batch_options)

        allow_null = options.delete(:null) != false
        if !allow_null
          # A `NOT NULL` constraint for the column is functionally equivalent
          # to creating a CHECK constraint `CHECK (column IS NOT NULL)` for the table
          add_not_null_constraint(table_name, column_name, validate: false)
          validate_not_null_constraint(table_name, column_name)

          if @connection.server_version >= 12_00_00
            # In PostgreSQL 12+ it is safe to "promote" a CHECK constraint to `NOT NULL` for the column
            change_column_null(table_name, column_name, false)
            remove_not_null_constraint(table_name, column_name)
          end
        end
      end
    end

    # Adds a NOT NULL constraint to the column
    #
    # @param table_name [String, Symbol]
    # @param column_name [String, Symbol]
    # @param name [String, Symbol] the constraint name.
    #     Defaults to `chk_rails_<identifier>`
    # @param validate [Boolean] whether or not the constraint should be validated
    #
    # @return [void]
    #
    # @example
    #   add_not_null_constraint(:users, :email, validate: false)
    #
    def add_not_null_constraint(table_name, column_name, name: nil, validate: true)
      if __column_not_nullable?(table_name, column_name) ||
         __not_null_constraint_exists?(table_name, column_name, name: name)
        Utils.say("NOT NULL constraint was not created: column #{table_name}.#{column_name} is already defined as `NOT NULL`")
      else
        expression = "#{column_name} IS NOT NULL"
        name ||= __not_null_constraint_name(table_name, column_name)
        add_check_constraint(table_name, expression, name: name, validate: false)

        if validate
          validate_not_null_constraint(table_name, column_name, name: name)
        end
      end
    end

    # Validates a NOT NULL constraint on the column
    #
    # @param table_name [String, Symbol]
    # @param column_name [String, Symbol]
    # @param name [String, Symbol] the constraint name.
    #     Defaults to `chk_rails_<identifier>`
    #
    # @return [void]
    #
    # @example
    #   validate_not_null_constraint(:users, :email)
    #
    # @example Explicit name
    #   validate_not_null_constraint(:users, :email, name: "check_users_email_null")
    #
    def validate_not_null_constraint(table_name, column_name, name: nil)
      name ||= __not_null_constraint_name(table_name, column_name)
      validate_check_constraint(table_name, name: name)
    end

    # Removes a NOT NULL constraint from the column
    #
    # @param table_name [String, Symbol]
    # @param column_name [String, Symbol]
    # @param name [String, Symbol] the constraint name.
    #     Defaults to `chk_rails_<identifier>`
    #
    # @return [void]
    #
    # @example
    #   remove_not_null_constraint(:users, :email)
    #
    # @example Explicit name
    #   remove_not_null_constraint(:users, :email, name: "check_users_email_null")
    #
    def remove_not_null_constraint(table_name, column_name, name: nil)
      name ||= __not_null_constraint_name(table_name, column_name)
      remove_check_constraint(table_name, name: name)
    end

    # Extends default method to be idempotent and automatically recreate invalid indexes.
    #
    # @see https://edgeapi.rubyonrails.org/classes/ActiveRecord/ConnectionAdapters/SchemaStatements.html#method-i-add_index
    #
    def add_index(table_name, column_name, **options)
      algorithm = options[:algorithm]

      __ensure_not_in_transaction! if algorithm == :concurrently

      column_names = __index_column_names(column_name || options[:column])

      index_name = options[:name]
      index_name ||= index_name(table_name, column_names)

      if index_exists?(table_name, column_name, **options)
        if __index_valid?(index_name)
          Utils.say("Index was not created because it already exists (this may be due to an aborted migration "\
            "or similar): table_name: #{table_name}, column_name: #{column_name}")
          return
        else
          Utils.say("Recreating invalid index: table_name: #{table_name}, column_name: #{column_name}")
          remove_index(table_name, column_name, name: index_name, algorithm: algorithm)
        end
      end

      disable_statement_timeout do
        # "CREATE INDEX CONCURRENTLY" requires a "SHARE UPDATE EXCLUSIVE" lock.
        # It only conflicts with constraint validations, creating/removing indexes,
        # and some other "ALTER TABLE"s.
        super(table_name, column_name, **options.merge(name: index_name))
      end
    end

    # Extends default method to be idempotent and accept `:algorithm` option for ActiveRecord <= 4.2.
    #
    # @see https://edgeapi.rubyonrails.org/classes/ActiveRecord/ConnectionAdapters/SchemaStatements.html#method-i-remove_index
    #
    def remove_index(table_name, column_name = nil, **options)
      algorithm = options[:algorithm]

      __ensure_not_in_transaction! if algorithm == :concurrently

      column_names = __index_column_names(column_name || options[:column])

      if index_exists?(table_name, column_name, **options)
        disable_statement_timeout do
          # "DROP INDEX CONCURRENTLY" requires a "SHARE UPDATE EXCLUSIVE" lock.
          # It only conflicts with constraint validations, other creating/removing indexes,
          # and some "ALTER TABLE"s.
          super(table_name, **options.merge(column: column_names))
        end
      else
        Utils.say("Index was not removed because it does not exist (this may be due to an aborted migration "\
          "or similar): table_name: #{table_name}, column_name: #{column_name}")
      end
    end

    # Extends default method to be idempotent and accept `:validate` option for ActiveRecord < 5.2.
    #
    # @see https://edgeapi.rubyonrails.org/classes/ActiveRecord/ConnectionAdapters/SchemaStatements.html#method-i-add_foreign_key
    #
    def add_foreign_key(from_table, to_table, validate: true, **options)
      if foreign_key_exists?(from_table, **options.merge(to_table: to_table))
        message = +"Foreign key was not created because it already exists " \
          "(this can be due to an aborted migration or similar): from_table: #{from_table}, to_table: #{to_table}"
        message << ", #{options.inspect}" if options.any?

        Utils.say(message)
      else
        super
      end
    end

    # Extends default method with disabled statement timeout while validation is run
    #
    # @see https://edgeapi.rubyonrails.org/classes/ActiveRecord/ConnectionAdapters/PostgreSQL/SchemaStatements.html#method-i-validate_foreign_key
    # @note This method was added in ActiveRecord 5.2
    #
    def validate_foreign_key(from_table, to_table = nil, **options)
      fk_name_to_validate = __foreign_key_for!(from_table, to_table: to_table, **options).name

      # Skip costly operation if already validated.
      return if __constraint_validated?(from_table, fk_name_to_validate, type: :foreign_key)

      disable_statement_timeout do
        # "VALIDATE CONSTRAINT" requires a "SHARE UPDATE EXCLUSIVE" lock.
        # It only conflicts with other validations, creating/removing indexes,
        # and some other "ALTER TABLE"s.
        execute("ALTER TABLE #{from_table} VALIDATE CONSTRAINT #{fk_name_to_validate}")
      end
    end

    # Extends default method to be idempotent
    #
    # @see https://edgeapi.rubyonrails.org/classes/ActiveRecord/ConnectionAdapters/SchemaStatements.html#method-i-add_check_constraint
    # @note This method was added in ActiveRecord 6.1
    #
    def add_check_constraint(table_name, expression, validate: true, **options)
      constraint_name = __check_constraint_name(table_name, expression: expression, **options)

      if __check_constraint_exists?(table_name, constraint_name)
        Utils.say("Check constraint was not created because it already exists (this may be due to an aborted migration "\
          "or similar) table_name: #{table_name}, expression: #{expression}, constraint name: #{constraint_name}")
      else
        super
      end
    end

    # Extends default method with disabled statement timeout while validation is run
    #
    # @see https://edgeapi.rubyonrails.org/classes/ActiveRecord/ConnectionAdapters/PostgreSQL/SchemaStatements.html#method-i-validate_check_constraint
    # @note This method was added in ActiveRecord 6.1
    #
    def validate_check_constraint(table_name, **options)
      constraint_name = __check_constraint_name!(table_name, **options)

      # Skip costly operation if already validated.
      return if __constraint_validated?(table_name, constraint_name, type: :check)

      disable_statement_timeout do
        # "VALIDATE CONSTRAINT" requires a "SHARE UPDATE EXCLUSIVE" lock.
        # It only conflicts with other validations, creating/removing indexes,
        # and some other "ALTER TABLE"s.
        super
      end
    end

    # Disables statement timeout while executing &block
    #
    # Long-running migrations may take more than the timeout allowed by the database.
    # Disable the session's statement timeout to ensure migrations don't get killed prematurely.
    #
    # Statement timeouts are already disabled in `add_index`, `remove_index`,
    # `validate_foreign_key`, and `validate_check_constraint` helpers.
    #
    # @return [void]
    #
    # @example
    #   disable_statement_timeout do
    #     add_index(:users, :email, unique: true, algorithm: :concurrently)
    #   end
    #
    def disable_statement_timeout
      prev_value = select_value("SHOW statement_timeout")
      execute("SET statement_timeout TO 0")

      yield
    ensure
      execute("SET statement_timeout TO #{quote(prev_value)}")
    end

    private
      # Private methods are prefixed with `__` to avoid clashes with existing or future
      # ActiveRecord methods
      def __ensure_not_in_transaction!(method_name = caller[0])
        if transaction_open?
          raise <<~MSG
            `#{method_name}` cannot run inside a transaction block.

            You can remove transaction block by calling `disable_ddl_transaction!` in the body of
            your migration class.
          MSG
        end
      end

      def __column_not_nullable?(table_name, column_name)
        query = <<~SQL
          SELECT is_nullable
          FROM information_schema.columns
          WHERE table_name = #{quote(table_name)}
            AND column_name = #{quote(column_name)}
        SQL

        select_value(query) == "NO"
      end

      def __not_null_constraint_exists?(table_name, column_name, name: nil)
        name ||= __not_null_constraint_name(table_name, column_name)
        __check_constraint_exists?(table_name, name)
      end

      def __not_null_constraint_name(table_name, column_name)
        __check_constraint_name(table_name, expression: "#{column_name}_not_null")
      end

      def __index_column_names(column_names)
        if column_names.is_a?(String) && /\W/.match?(column_names)
          column_names
        else
          Array(column_names)
        end
      end

      def __index_valid?(index_name)
        select_value <<~SQL
          SELECT indisvalid
          FROM pg_index i
          JOIN pg_class c
            ON i.indexrelid = c.oid
          WHERE c.relname = #{quote(index_name)}
        SQL
      end

      def __foreign_key_for!(from_table, **options)
        foreign_key_for(from_table, **options) ||
          raise(ArgumentError, "Table '#{from_table}' has no foreign key for #{options[:to_table] || options}")
      end

      def __constraint_validated?(table_name, name, type:)
        contype = type == :check ? "c" : "f"

        select_value(<<~SQL)
          SELECT convalidated
          FROM pg_catalog.pg_constraint con
          WHERE con.conrelid = #{quote(table_name)}::regclass
            AND con.conname = #{quote(name)}
            AND con.contype = '#{contype}'
        SQL
      end

      def __check_constraint_name!(table_name, expression: nil, **options)
        constraint_name = __check_constraint_name(table_name, expression: expression, **options)

        if __check_constraint_exists?(table_name, constraint_name)
          constraint_name
        else
          raise(ArgumentError, "Table '#{table_name}' has no check constraint for #{expression || options}")
        end
      end

      def __check_constraint_name(table_name, **options)
        options.fetch(:name) do
          expression = options.fetch(:expression)
          identifier = "#{table_name}_#{expression}_chk"
          hashed_identifier = Digest::SHA256.hexdigest(identifier).first(10)

          "chk_rails_#{hashed_identifier}"
        end
      end

      def __check_constraint_exists?(table_name, constraint_name)
        check_sql = <<~SQL.squish
          SELECT COUNT(*)
          FROM pg_catalog.pg_constraint con
            INNER JOIN pg_catalog.pg_class cl
              ON cl.oid = con.conrelid
          WHERE con.contype = 'c'
            AND con.conname = #{quote(constraint_name)}
            AND cl.relname = #{quote(table_name)}
        SQL

        select_value(check_sql).to_i > 0
      end
  end
end