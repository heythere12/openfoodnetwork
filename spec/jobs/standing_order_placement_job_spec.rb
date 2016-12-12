require 'spec_helper'

describe StandingOrderPlacementJob do

  describe "finding standing_order orders for the specified order cycle" do
    let(:shop) { create(:distributor_enterprise) }
    let(:order_cycle1) { create(:simple_order_cycle, coordinator: shop) }
    let(:order_cycle2) { create(:simple_order_cycle, coordinator: shop) }
    let(:schedule) { create(:schedule, order_cycles: [order_cycle1, order_cycle2]) }
    let(:standing_order1) { create(:standing_order, shop: shop, schedule: schedule) }
    let(:standing_order2) { create(:standing_order, shop: shop, schedule: schedule, paused_at: 1.minute.ago) }
    let(:standing_order3) { create(:standing_order, shop: shop, schedule: schedule, canceled_at: 1.minute.ago) }
    let(:standing_order4) { create(:standing_order, shop: shop, schedule: schedule, begins_at: 1.minute.from_now) }
    let(:standing_order5) { create(:standing_order, shop: shop, schedule: schedule, ends_at: 1.minute.ago) }
    let!(:order1) { create(:order, completed_at: 5.minutes.ago) } # Complete + Linked + OC Matches
    let!(:order2) { create(:order) } # Incomplete + Not-Linked + OC Matches
    let!(:order3) { create(:order) } # Incomplete + Linked + OC Mismatch
    let!(:order4) { create(:order) } # Incomplete + Linked + OC Matches + Paused
    let!(:order5) { create(:order) } # Incomplete + Linked + OC Matches + Cancelled
    let!(:order6) { create(:order) } # Incomplete + Linked + OC Matches + Yet To Begin
    let!(:order7) { create(:order) } # Incomplete + Linked + OC Matches + Ended
    let!(:order8) { create(:order) } # Incomplete + Linked + OC Matches
    let!(:proxy_order1) { create(:proxy_order, standing_order: standing_order1, order: order1, order_cycle: order_cycle1) }
    let!(:proxy_order3) { create(:proxy_order, standing_order: standing_order1, order: order3, order_cycle: order_cycle2) }
    let!(:proxy_order4) { create(:proxy_order, standing_order: standing_order2, order: order4, order_cycle: order_cycle1) }
    let!(:proxy_order5) { create(:proxy_order, standing_order: standing_order3, order: order5, order_cycle: order_cycle1) }
    let!(:proxy_order6) { create(:proxy_order, standing_order: standing_order4, order: order6, order_cycle: order_cycle1) }
    let!(:proxy_order7) { create(:proxy_order, standing_order: standing_order5, order: order7, order_cycle: order_cycle1) }
    let!(:proxy_order8) { create(:proxy_order, standing_order: standing_order1, order: order8, order_cycle: order_cycle1) }

    let!(:job) { StandingOrderPlacementJob.new(order_cycle1) }

    it "only returns incomplete orders in the relevant order cycle that are linked to a standing order" do
      orders = job.send(:orders)
      expect(orders).to include order8
      expect(orders).to_not include order1, order2, order3, order4, order5, order6, order7
    end
  end

  describe "processing an order containing items with insufficient stock" do
    let(:order_cycle) { create(:simple_order_cycle) }
    let(:order) { create(:order, order_cycle: order_cycle) }
    let(:variant1) { create(:variant, count_on_hand: 5) }
    let(:variant2) { create(:variant, count_on_hand: 2) }
    let(:variant3) { create(:variant, count_on_hand: 0) }
    let(:line_item1) { create(:line_item, order: order, variant: variant1, quantity: 5) }
    let(:line_item2) { create(:line_item, order: order, variant: variant2, quantity: 2) }
    let(:line_item3) { create(:line_item, order: order, variant: variant3, quantity: 0) }

    let!(:job) { StandingOrderPlacementJob.new(order_cycle) }

    before do
      Spree::Config.set(:allow_backorders, false)
      line_item1.update_attribute(:quantity, 3)
      line_item2.update_attribute(:quantity, 3)
      line_item3.update_attribute(:quantity, 3)
    end

    it "caps quantity at the stock level, and reports the change" do
      changes = job.send(:cap_quantity_and_store_changes, order.reload)
      expect(line_item1.reload.quantity).to be 3 # not capped
      expect(line_item2.reload.quantity).to be 2 # capped
      expect(line_item3.reload.quantity).to be 0 # capped
      expect(changes[line_item2.id]).to be 3
      expect(changes[line_item3.id]).to be 3
    end
  end

  describe "processing a standing order order" do
    let(:standing_order) { create(:standing_order, with_items: true) }
    let(:proxy_order) { create(:proxy_order, standing_order: standing_order) }
    let!(:order) { proxy_order.initialise_order! }
    let(:changes) { {} }

    let!(:job) { StandingOrderPlacementJob.new(proxy_order.order_cycle) }

    before do
      expect_any_instance_of(Spree::Payment).to_not receive(:process!)
      allow(job).to receive(:cap_quantity_and_store_changes) { changes }
      allow(job).to receive(:send_placement_email).and_call_original
    end

    it "moves orders to completion, but does not process the payment" do
      # If this spec starts complaining about no shipping methods being available
      # on CI, there is probably another spec resetting the currency though Rails.cache.clear
      ActionMailer::Base.deliveries.clear
      expect{job.send(:process, order)}.to change{order.reload.completed_at}.from(nil)
      expect(order.completed_at).to be_within(5.seconds).of Time.now
      expect(order.payments.first.state).to eq "checkout"
    end

    it "sends only a placement email, no confirmation emails" do
      ActionMailer::Base.deliveries.clear
      expect{job.send(:process, order)}.to_not enqueue_job ConfirmOrderJob
      expect(job).to have_received(:send_placement_email).with(order, changes).once
      expect(ActionMailer::Base.deliveries.count).to be 1
    end
  end
end
