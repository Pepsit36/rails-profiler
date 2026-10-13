# frozen_string_literal: true

require_relative "../demo_helper"

RSpec.describe "Orders report" do
  before do
    3.times do |i|
      author = Author.create!(name: "Seller #{i}", email: "seller#{i}@myapp.test")
      Post.create!(title: "Item #{i}", body: "Demo item", author: author)
    end
  end

  it "lists every item with its seller" do
    rows = Post.all.map { |post| [post.title, post.author.name] } # one query per seller: N+1
    expect(rows.size).to eq(3)
  end

  it "caches the monthly totals" do
    totals = Rails.cache.fetch("report/monthly") { { count: Post.count } }
    expect(totals[:count]).to eq(3)
  end

  it "rounds the revenue to the cent" do
    expect(18_420.456.round(2)).to eq(18_420.46)
  end
end
