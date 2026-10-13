# frozen_string_literal: true

require_relative "../demo_helper"

RSpec.describe "Customers" do
  it "creates a customer with a normalized email" do
    user = User.create!(name: "Jane Example", email: "jane@myapp.test")
    expect(User.find(user.id).email).to eq("jane@myapp.test")
  end

  it "finds customers by name" do
    %w[Alice Bob Carol].each { |name| User.create!(name: name, email: "#{name.downcase}@myapp.test") }
    expect(User.where("name LIKE ?", "A%").count).to eq(1)
  end
end
