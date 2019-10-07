require 'open_food_network/scope_product_to_hub'

module OpenFoodNetwork
  class ProductsRenderer
    class NoProducts < RuntimeError; end

    def initialize(distributor, order_cycle, customer, params = {})
      @distributor = distributor
      @order_cycle = order_cycle
      @customer = customer
      @params = params
    end

    def products_json
      if order_cycle && distributor && products
        enterprise_fee_calculator = EnterpriseFeeCalculator.new distributor, order_cycle

        ActiveModel::ArraySerializer.new(products,
                                         each_serializer: Api::ProductSerializer,
                                         current_order_cycle: order_cycle,
                                         current_distributor: distributor,
                                         variants: variants_for_shop_by_id,
                                         master_variants: master_variants_for_shop_by_id,
                                         enterprise_fee_calculator: enterprise_fee_calculator,).to_json
      else
        raise NoProducts
      end
    end

    private

    attr_reader :order_cycle, :distributor, :customer, :params

    def products
      return unless order_cycle

      @products ||= begin
        results = distributed_products.products_relation.order(taxon_order)

        filter_and_paginate(results).each { |product| product_scoper.scope(product) }
      end
    end

    def product_scoper
      ScopeProductToHub.new(distributor)
    end

    def filter_and_paginate(query)
      query.ransack(params[:q]).result.page(params[:page] || 1).per(params[:per_page] || 10)
    end

    def distributed_products
      OrderCycleDistributedProducts.new(distributor, order_cycle, customer)
    end

    def taxon_order
      if distributor.preferred_shopfront_taxon_order.present?
        distributor
          .preferred_shopfront_taxon_order
          .split(",").map { |id| "primary_taxon_id=#{id} DESC" }
          .join(",") + ", name ASC"
      else
        "name ASC"
      end
    end

    def variants_for_shop
      @variants_for_shop ||= begin
        scoper = OpenFoodNetwork::ScopeVariantToHub.new(distributor)

        distributed_products.variants_relation.
          includes(:default_price, :stock_locations, :product).
          where(product_id: products).
          each { |v| scoper.scope(v) }
      end
    end

    def variants_for_shop_by_id
      index_by_product_id variants_for_shop.reject(&:is_master)
    end

    def master_variants_for_shop_by_id
      index_by_product_id variants_for_shop.select(&:is_master)
    end

    def index_by_product_id(variants)
      variants.each_with_object({}) do |v, vs|
        vs[v.product_id] ||= []
        vs[v.product_id] << v
      end
    end
  end
end
