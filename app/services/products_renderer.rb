# frozen_string_literal: true

require 'open_food_network/scope_product_to_hub'


class ProductsRenderer # rubocop:disable Metrics/ClassLength
  include Pagy::Backend

  class NoProducts < RuntimeError; end
  DEFAULT_PER_PAGE = 10

  def initialize(distributor, order_cycle, customer, args = {})
    @distributor = distributor
    @order_cycle = order_cycle
    @customer = customer
    @args = args
  end

  def products_json
    raise NoProducts unless order_cycle && distributor && products

    ActiveModel::ArraySerializer.new(products,
                                     each_serializer: Api::ProductSerializer,
                                     current_order_cycle: order_cycle,
                                     current_distributor: distributor,
                                     variants: variants_for_shop_by_id,
                                     enterprise_fee_calculator:).to_json
  end

  private

  attr_reader :order_cycle, :distributor, :customer, :args

  def products
    return unless order_cycle

    @products ||= begin
      results = products_relation.
        order(Arel.sql(products_order))

      results = filter(results)
      # Scope results with variant_overrides
      paginate(results).each { |product| product_scoper.scope(product) }
    end
  end

  def product_scoper
    @product_scoper ||= OpenFoodNetwork::ScopeProductToHub.new(distributor)
  end

  def enterprise_fee_calculator
    OpenFoodNetwork::EnterpriseFeeCalculator.new distributor, order_cycle
  end

  # TODO refactor this, distributed_products should be able to give use the relation based
  # on the sorting method, same for ordering. It would prevent the SQL implementation from
  # leaking here
  def products_relation
    if distributor.preferred_shopfront_product_sorting_method == "by_category" &&
       distributor.preferred_shopfront_taxon_order.present?
      return distributed_products.products_taxons_relation
    end

    distributed_products.products_supplier_relation
  end

  # TODO: refactor to address CyclomaticComplexity
  def filter(query) # rubocop:disable Metrics/CyclomaticComplexity
    supplier_properties = args[:q]&.slice("with_variants_supplier_properties")

    ransack_results = query.ransack(args[:q]).result.to_a

    return ransack_results if supplier_properties.blank?

    with_properties = args[:q]&.dig("with_properties")
    supplier_properties_results = []

    if supplier_properties.present?
      # We can't search on an association's scope with ransack, a work around is to define
      # the a scope on the parent (Spree::Product) but because we are joining on "first_variant"
      # to get the supplier it doesn't work, so we do the filtering manually here
      # see:
      #   OrderCycleDistributedProducts#products_supplier_relation
      #   OrderCycleDistributedProducts#supplier_property_join
      supplier_property_ids = supplier_properties["with_variants_supplier_properties"]
      supplier_properties_results = distributed_products.supplier_property_join(query).
        where(producer_properties: { property_id: supplier_property_ids }).
        where(inherits_properties: true)
    end

    if supplier_properties_results.present? && with_properties.present?
      # apply "OR" between property search
      return ransack_results | supplier_properties_results
    end

    # Intersect the result to apply "AND" with other search criteria
    return ransack_results.intersection(supplier_properties_results) \
      unless supplier_properties_results.empty?

    # We should get here but just in case we return the ransack results
    ransack_results
  end

  def paginate(results)
    _pagy, paginated_results = pagy_array(
      results,
      page: args[:page] || 1,
      items: args[:per_page] || DEFAULT_PER_PAGE
    )

    paginated_results
  end

  def distributed_products
    OrderCycles::DistributedProductsService.new(distributor, order_cycle, customer)
  end

  # TODO refactor, see above
  def products_order
    if distributor.preferred_shopfront_product_sorting_method == "by_producer" &&
      distributor.preferred_shopfront_producer_order.present?
      order_by_producer = distributor
                            .preferred_shopfront_producer_order
                            .split(",").map { |id| "first_variant.supplier_id=#{id} DESC" }
                            .join(", ")
      "#{order_by_producer}, spree_products.name ASC, spree_products.id ASC"
    elsif distributor.preferred_shopfront_product_sorting_method == "by_category" &&
      distributor.preferred_shopfront_taxon_order.present?
      order_by_category = distributor
                            .preferred_shopfront_taxon_order
                            .split(",").map { |id| "first_variant.primary_taxon_id=#{id} DESC" }
                            .join(", ")
      "#{order_by_category}, spree_products.name ASC, spree_products.id ASC"
    else
      "spree_products.name ASC, spree_products.id"
    end
  end

  def variants_for_shop
    @variants_for_shop ||= begin
      scoper = OpenFoodNetwork::ScopeVariantToHub.new(distributor)

      # rubocop:disable Rails/FindEach # .each returns an array, .find_each returns nil
      distributed_products.variants_relation.
        includes(:default_price, :stock_locations, :product).
        where(product_id: products).
        each { |v| scoper.scope(v) } # Scope results with variant_overrides
      # rubocop:enable Rails/FindEach
    end
  end

  def variants_for_shop_by_id
    index_by_product_id variants_for_shop
  end

  def index_by_product_id(variants)
    variants.each_with_object({}) do |v, vs|
      vs[v.product_id] ||= []
      vs[v.product_id] << v
    end
  end
end
