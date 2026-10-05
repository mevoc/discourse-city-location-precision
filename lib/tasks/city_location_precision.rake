# frozen_string_literal: true

desc "Re-coarsen every stored topic location to the configured grid (PRD section 4.5 / D8)"
task "city_location_precision:recoarsen" => :environment do
  # The plugin's hooks hold from the moment it is installed. This covers what was stored
  # before that, or while the grid was set finer: rows written by an earlier instance, an
  # import, or a restored backup. Without it, "no coordinate is persisted at finer than the
  # configured grid" is only true going forward.
  changed = 0

  Topic
    .joins("INNER JOIN topic_custom_fields tcf ON tcf.topic_id = topics.id")
    .where("tcf.name = 'location'")
    .find_each do |topic|
      before = Locations::TopicLocationStore.fetch(topic)
      next if before.blank?

      after = CityLocationPrecision.apply(before)
      next if after == before

      # Goes through assign, so the custom field and the projection move together.
      Locations::TopicLocationStore.assign(topic: topic, location: after)
      topic.save!
      changed += 1
    end

  # Catches any projection row whose topic has no custom field left to re-assign from.
  Locations::TopicLocation.find_each do |row|
    row.save! if row.changed? || row.latitude != CityLocationPrecision.round_coordinate(row.latitude)
  end

  puts "city_location_precision: re-coarsened #{changed} topic location(s) to #{CityLocationPrecision.decimals} decimals"
end
