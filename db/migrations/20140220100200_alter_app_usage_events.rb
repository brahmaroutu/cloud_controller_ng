Sequel.migration do
  change do
    alter_table(:app_usage_events) do
      add_column :app_buildpack, String
      add_column :app_detected_buildpack, String
    end
  end
end

