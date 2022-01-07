# frozen_string_literal: true

module OnlineMigrations
  # Class representing configuration options for the gem.
  class Config
    include ErrorMessages

    # The database version against which the checks will be performed
    #
    # If your development database version is different from production, you can specify
    # the production version so the right checks run in development.
    #
    # @example Set specific target version
    #   OnlineMigrations.config.target_version = 10
    #
    attr_accessor :target_version

    # Whether to perform checks when migrating down
    #
    # Disabled by default
    # @return [Boolean]
    #
    attr_accessor :check_down

    attr_accessor :error_messages

    # Tables that are in the process of being renamed
    #
    # @return [Hash] Keys are old table names, values - new table names
    # @example To add a table
    #   OnlineMigrations.config.table_renames["users"] = "clients"
    #
    attr_accessor :table_renames

    # Columns that are in the process of being renamed
    #
    # @return [Hash] Keys are table names, values - hashes with old column names as keys
    #   and new column names as values
    # @example To add a column
    #   OnlineMigrations.config.column_renames["users] = { "name" => "first_name" }
    #
    attr_accessor :column_renames

    def initialize
      @table_renames = {}
      @column_renames = {}
      @error_messages = ERROR_MESSAGES
      @check_down = false
    end
  end
end