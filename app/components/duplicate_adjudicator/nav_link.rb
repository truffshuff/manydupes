# frozen_string_literal: true

class Components::DuplicateAdjudicator::NavLink < Components::Base
  def view_template
    return unless current_user&.is_administrator?

    prefix = Rails.application.config.relative_url_root.to_s.chomp("/")
    a href: "#{prefix}/duplicate_adjudicator/", class: "nav-link text-center" do
      Icon(icon: "copy", role: "presentation", effect: "d-block fs-5 lh-1 mb-1")
      span { t("manydupes.name") }
    end
  end
end
