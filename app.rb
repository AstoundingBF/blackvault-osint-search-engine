require 'sinatra'
require 'csv'
require 'bcrypt'
require 'mysql2'
require 'securerandom'
require 'redis'
require 'json'

redis = Redis.new
$index = {}

CSV.foreach('data.csv', headers: true) do |row|
  record = row.to_h

  record_id = record['ID']
  $index[record_id] = record

  # Index by other fields for faster searching
  index_fields = ['firstName', 'lastName', 'Email', 'DOB', 'Password', 'phone', 'source']
  index_fields.each do |field|
    field_value = record[field]
    next if field_value.nil?

    field_index = $index[field] ||= {}
    field_index[field_value] ||= []
    field_index[field_value] << record_id
  end
end

get '/dataformats' do
  erb :dataformats
end

# Routes
get '/' do
  erb :index
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

def search_terms_invalid?(search_terms)
  search_terms.each_value do |value|
    return true if value.nil? || value.strip.empty?
  end
  false
end



get '/results' do
  query = session[:query]
  search_terms = session[:search_terms]

  results = search_records(query, search_terms)
  calculate_relevance!(results, query, search_terms)

  erb :results, locals: { results: results }
end



get '/export' do
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
  else
    "Invalid number of records to export"
  end
end

def search_records(query, search_terms)
  results = []

  if search_terms.nil? || search_terms.empty?
    # No search terms provided, return all records
    results = $index.values
  else
    # Perform indexed search based on search terms
    matching_record_ids = []

    search_terms.each do |term, value|
      field_index = $index[term]
      next if field_index.nil?

      record_ids = field_index[value]
      next if record_ids.nil?

      matching_record_ids << record_ids
    end

    # Get the intersection of all matching record IDs
    matching_ids = matching_record_ids.inject(:&)

    matching_ids.each do |record_id|
      results << $index[record_id]
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
    value[1..-2]  # Remove the surrounding quotes
  else
    value
  end
end

def calculate_relevance!(results, query, search_terms)
  results.each do |result|
    matching_fields = result.select { |_, value| value.to_s.downcase.include?(query.to_s.downcase) }
    matching_search_terms = search_terms.all? { |term, value| result[term].to_s.downcase.include?(value.to_s.downcase) }

    total_fields = result.size - 2  # Exclude 'ID' and 'Relevance' fields
    total_relevant_fields = matching_fields.size + (matching_search_terms ? 1 : 0)
    relevance = (total_relevant_fields.to_f / total_fields) * 100

    result['Relevance'] = relevance.to_i
  end

  results.sort_by! { |result| -result['Relevance'] }  # Sort results by relevance in descending order
end

def retrieve_search_results(query)
  cache_key = "search:#{query}"
  cached_results = redis.get(cache_key)

  if cached_results
    JSON.parse(cached_results)
  else
    perform_search(query)
  end
end