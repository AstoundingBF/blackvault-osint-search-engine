require 'sinatra'
require 'cassandra'
require 'redis'
require 'json'
require 'csv'

# Rate limit variables
RATE_LIMIT_PERIOD = 30 # seconds
RATE_LIMIT_MAX_REQUESTS = 1
$last_export_time = nil
$request_count = 0

configure do
  enable :sessions
  set :views, File.dirname(__FILE__) + '/views'

  # Establish a connection to Cassandra
  cluster = Cassandra.cluster
  $session = cluster.connect('bigdata')

  # Initialize Redis
  $redis = Redis.new
end

def index_records(session, batch_size)
  index = {}
  total_records = 0

  session.execute('SELECT * FROM users').each do |row|
    record = {
      'ID' => row['id'],
      'email' => row['email'],
      'password' => row['password'],
      'firstName' => row['first_name'],
      'lastName' => row['last_name'],
      'address' => row['address'],
      'zipcode' => row['zip_code'],
      'age' => row['age'],
      'source' => row['source']
    }
    record_id = record['ID']
    index[record_id] = record

    # Create field index
    record.each do |field, value|
      next if field == 'ID' # Skip the ID field

      $redis.sadd("#{field}:#{value}", record_id)
    end

    # Process the batch after reaching the specified batch size
    if index.size >= batch_size
      process_batch(index)
      total_records += index.size
      index.clear
      puts "Indexed #{total_records} records"
    end
  end

  # Process any remaining records in the last batch
  process_batch(index) unless index.empty?
  total_records += index.size
  puts "Indexed all #{total_records} records"
end

def process_batch(index)
  index.each do |record_id, record|
    $redis.hmset(record_id, record.flatten)
  end
end

def search_records(query, search_terms)
  results = []

  if search_terms.nil? || search_terms.empty?
    # No search terms provided, return all records
    results = $session.execute('SELECT * FROM users')
  else
    # Perform indexed search based on search terms
    search_results = []
    search_terms.each do |term, value|
      search_results << $redis.smembers("#{term}:#{value}")
    end

    record_ids = search_results.inject(:&)
    record_ids.each do |record_id|
      results << $redis.hgetall(record_id)
    end
  end

  results
end




def parse_search_terms(search_terms_string)
  return {} if search_terms_string.nil?

  search_terms = {}
  terms = search_terms_string.split(',')
  terms.each do |term|
    key, value = term.split(':')
    search_terms[key.strip] = parse_search_value(value.strip)
  end

  search_terms
end

def parse_search_value(value)
  if value.start_with?('"') && value.end_with?('"')
    value[1..-2]
  else
    value
  end
end

def calculate_relevance!(results, query, search_terms)
  results.each do |result|
    matching_fields = result.select { |_, value| value.to_s.downcase.include?(query.to_s.downcase) }
    matching_search_terms = search_terms.all? { |term, value| result[term].to_s.downcase.include?(value.to_s.downcase) }

    total_fields = result.size - 2
    total_relevant_fields = matching_fields.size + (matching_search_terms ? 1 : 0)
    relevance = (total_relevant_fields.to_f / total_fields) * 100

    result['Relevance'] = relevance.to_i
  end

  results.sort_by! { |result| -result['Relevance'] }
end

batch_size = 1000

Thread.new do
  index_records($session, batch_size)
end

get '/dataformats' do
  erb :dataformats
end

get '/' do
  erb :index
end

get '/apidoc' do
  erb :api
end

get '/search' do
  session[:query] = params[:query]
  session[:search_terms] = params[:search_terms]
  redirect '/results'
end

post '/search' do
  begin
    query = params[:query]
    search_terms = parse_search_terms(params[:search_terms])

    if search_terms_invalid?(search_terms)
      @error_message = 'Invalid search terms. Please use the correct format.'
      erb :index
    else
      results = search_records(query, search_terms)
      calculate_relevance!(results, query, search_terms)

      erb :results, locals: { results: results }
    end
  rescue StandardError => e
    @error_message = 'Invalid search terms. Please use the correct format. Correct format is: <a href="/dataformats">Format Tutorial</a> '
    erb :index
  end
end

get '/results' do
  query = session[:query]
  search_terms = session[:search_terms]

  results = search_records(query, search_terms)
  calculate_relevance!(results, query, search_terms)

  # Limit the results to 100 records
  limited_results = results.first(100)

  erb :results, locals: { results: limited_results }
end

def search_terms_invalid?(search_terms)
  search_terms.each_value do |value|
    return true if value.nil? || value.strip.empty?
  end
  false
end

get '/export' do
  if rate_limited?
    return 'Too many requests. Please try again later.'
  end

  num_records = params['num_records'].to_i
  query = session[:query]
  search_terms = session[:search_terms]
  results = search_records(query, search_terms)

  if num_records <= results.length
    records_to_export = results.first(num_records)

    content_type 'application/csv'
    attachment 'export.csv'

    CSV.generate do |csv|
      csv << results.first.keys
      records_to_export.each do |record|
        csv << record.values
      end
    end

    update_rate_limit()
  else
    "Invalid number of records to export"
  end
end

def rate_limited?
  current_time = Time.now
  if $last_export_time.nil? || (current_time - $last_export_time) > RATE_LIMIT_PERIOD
    $last_export_time = current_time
    $request_count = 1
    false
  else
    $request_count += 1
    $request_count > RATE_LIMIT_MAX_REQUESTS
  end
end

def update_rate_limit
  $request_count = 0
end

get '/api/search' do
  api_key = params['api_key']
  halt 401, 'Unauthorized' unless authenticate(api_key)

  query = params['query']
  search_terms = parse_search_terms(params['search_terms'])

  if search_terms_invalid?(search_terms)
    halt 400, 'Invalid search terms. Please use the correct format.'
  end

  results = search_records(query, search_terms)
  calculate_relevance!(results, query, search_terms)

  content_type :json
  results.to_json
end

get '/api/export' do
  api_key = params['api_key']
  halt 401, 'Unauthorized' unless authenticate(api_key)

  if rate_limited?
    halt 429, 'Too many requests. Please try again later.'
  end

  num_records = params['num_records'].to_i
  query = params['query']
  search_terms = parse_search_terms(params['search_terms'])
  results = search_records(query, search_terms)

  if num_records <= results.length
    records_to_export = results.first(num_records)

    content_type 'application/csv'
    attachment 'export.csv'

    CSV.generate do |csv|
      csv << results.first.keys
      records_to_export.each do |record|
        csv << record.values
      end
    end

    update_rate_limit()
  else
    halt 400, 'Invalid number of records to export'
  end
end

def authenticate(api_key)
  API_KEYS.include?(api_key)
end

API_KEYS = ['4f46c87b-897f-4879-9960-a71c5ae5951d', 'd9017477-8191-43a1-9cf7-852fc2a8a87e', '27448f70-3016-429a-966f-300520347f1d']
