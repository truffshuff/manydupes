# frozen_string_literal: true

class Components::DuplicateAdjudicator::NavLink < Components::Base
  def view_template
    return unless current_user&.is_administrator?

    prefix = Rails.application.config.relative_url_root.to_s.chomp("/")
    a(href: "#{prefix}/duplicate_adjudicator/", class: "nav-link") { plain t("manydupes.name") }
  end
end
