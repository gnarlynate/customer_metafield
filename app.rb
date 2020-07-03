require 'pry'
require 'shopify_api'
require 'base64'
require 'openssl'
require 'sinatra'
require 'httparty'
require 'dotenv'
Dotenv.load

API_KEY = ENV['API_KEY']
PASSWORD = ENV['PASSWORD']
WEBHOOK_SECRET = ENV['SECRET']
SHOP_NAME = 'bowes-guitars'
SHOP_URL = "https://#{API_KEY}:#{PASSWORD}@#{SHOP_NAME}.myshopify.com/admin"
ShopifyAPI::Base.site = SHOP_URL
ShopifyAPI::Base.api_version = '2020-04'

def verify_webhook(data, hmac)
  digest = OpenSSL::Digest.new('sha256')
  calculated_hmac = Base64.encode64(OpenSSL::HMAC.digest(digest, WEBHOOK_SECRET, data)).strip
  hmac == calculated_hmac
end

def get_product_limit_tags(line_item)
  product_id = line_item['product_id']
  product = ShopifyAPI::Product.find(product_id)
  product.tags.split.select {|tag| tag.start_with? "limit_" }
end

def get_customer(json)
  customer_id = json['customer']['id']
  ShopifyAPI::Customer.find(customer_id)
end

def get_order(json)
  order_id = json['id']
  order = ShopifyAPI::Order.find(order_id)
end

def get_customer_metafield(json)
  customer = get_customer(json)
  line_items = json['line_items']
  customer_metafields = []
  line_items.each do |line|
    customer_metafields << customer.metafields.select { |metafield| metafield.key == line['sku']}[0]
  end
  customer_metafields
end

def tag_customer(json_customer, line)
  customer = json_customer
  customer_tags = customer.tags.split(',')
  customer_tags << "purchased_#{line['sku']}"
  customer.tags = customer_tags.join(',')
  customer.save
end

def tag_order(json_order,line)
  order = json_order
  order_tags = order.tags.split(',')
  order_tags << "limit_exceeded_#{line['sku']}"
  order.tags = order_tags.join(',')
  order.save
end

def customer_order_tag_logic(json, metafield, line, qty)
  customer = get_customer(json)
  order = get_order(json)
  if metafield.value > qty
    tag_order(order, line)
    tag_customer(customer, line)
  elsif metafield.value == qty
    tag_customer(customer, line)
  end
end

post '/webhook' do
    hmac = env['HTTP_X_SHOPIFY_HMAC_SHA256']
    request.body.rewind
    data = request.body.read
    verified = verify_webhook(data, hmac)
    return unless verified
      status 200

      json_data = JSON.parse(data)
      found_ids = Hash.new(0)
      json_data["line_items"].each do |line_item|
        
        limit_tags = get_product_limit_tags(line_item)
        if limit_tags.size >= 1
          qty_limit = limit_tags.first.split('_')[1].to_i
          customer_metafields = get_customer_metafield(json_data)

          customer_metafields.each do |metafield|
            if metafield && metafield.key == line_item['sku']
              metafield.value += 1
              metafield.save
              customer_order_tag_logic(json_data, metafield, line_item, qty_limit)
            else
              customer = get_customer(json_data)
              metafield = {
                namespace: 'product',
                key: line_item['sku'],
                value: line_item['quantity'],
                value_type: 'integer'
              }
              customer.add_metafield(ShopifyAPI::Metafield.new(metafield))
            end
          end
        end
      end
      # end
  puts "200 OK"
end