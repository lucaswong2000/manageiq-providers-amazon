class ManageIQ::Providers::Amazon::NetworkManager::EventCatcher < ::MiqEventCatcher

  def self.ems_class
    ManageIQ::Providers::Amazon::NetworkManager
  end

  def self.settings_name
    :event_catcher_amazon_network
  end
end
