# This tool is for converting GraphQL schema to HAR file.
# We will be using https://github.com/NeuraLegion/har for this.

require "har"
require "http"
require "colorize"
require "uuid"

module Harph
  VERSION = "0.1.0"

  INTROSPECTION_REQUEST_BODY = <<-EOF
  {
    "query":"{__schema{queryType{name}mutationType{name}subscriptionType{name}types{...FullType}directives{name description locations args{...InputValue}}}}fragment FullType on __Type{kind name description fields(includeDeprecated:true){name description args{...InputValue}type{...TypeRef}isDeprecated deprecationReason}inputFields{...InputValue}interfaces{...TypeRef}enumValues(includeDeprecated:true){name description isDeprecated deprecationReason}possibleTypes{...TypeRef}}fragment InputValue on __InputValue{name description type{...TypeRef}defaultValue}fragment TypeRef on __Type{kind name ofType{kind name ofType{kind name ofType{kind name ofType{kind name ofType{kind name ofType{kind name ofType{kind name}}}}}}}}"
  }
  EOF

  class Convert
    @introspection_response : String
    @url : URI

    def initialize(@url : URI)
      resp = HTTP::Client.post(@url, headers: HTTP::Headers{"Content-Type" => "application/json"}, body: INTROSPECTION_REQUEST_BODY).body.to_s
      @introspection_response = resp
      puts "Introspection response received. via #{@url}"
    end

    def to_har
      har = HAR::Log.new
      puts "Generating HAR file..."
      parsed = JSON.parse(@introspection_response)
      schema = parsed["data"]["__schema"]
      # Iterate over queries and mutations
      # Assuming schema is the parsed introspection response
      types = schema["types"]

      # Filter out the queries and mutations
      queries_mutations = types.as_a.select { |type| type["kind"] == "OBJECT" && ["Query", "Mutations", "Subscription"].includes?(type["name"]) }
      puts "Found #{queries_mutations.size} queries/mutations"
      queries_mutations.each_with_index do |operation, i|
        next unless operation

        case operation["name"].try &.as_s
        when "Query"
          operation_name = "query"
        when "Mutations"
          operation_name = "mutation"
        when "Subscription"
          operation_name = "subscription"
        else
          puts "Skipping #{operation["name"]} as it's not a query or mutation".colorize(:red)
          next
        end

        fields = operation["fields"]?
        next unless fields

        # Go over each field and generate a HAR request
        fields.as_a.each do |field|
          field_name = field["name"]

          if build_args(field["args"].as_a).empty?
            operation_query = "#{operation_name.downcase} #{field_name} { #{build_selections(field, types)} }"
          else
            operation_query = "#{operation_name.downcase} { #{field_name}#{build_args(field["args"].as_a)} { #{build_selections(field, types)} } }"
          end
          # Send the request and get the response
          response = HTTP::Client.post(@url, headers: HTTP::Headers{"Content-Type" => "application/json"}, body: "{\"query\": \"#{operation_query}\"}")
          if response.status.success?
            puts "Adding #{operation_query} to HAR file".colorize(:green)
            add_to_har(har, operation_query, response)
          else
            puts "Skipping #{operation_query} as it failed with #{response.status.code}".colorize(:red)
            puts "---> Response: #{response.body.to_s}".colorize(:red)
          end
        end
      end
      # Save the HAR file
      File.open("#{@url.host}_#{Time.utc.to_unix}.har", "w") do |file|
        file.puts HAR::Data.new(log: har).to_json
        puts "HAR file generated with #{har.entries.size} entries"
      end
    end

    private def build_selections(field, types) : String
      case field["type"]["kind"]
      when "LIST"
        # This will grab the name of the object inside the list
        from_object = field["type"]["ofType"]["name"]
        # then we go over the types and find the object
        deep_selector_build(types, from_object)
      when "OBJECT"
        # This will grab the name of the object inside the list
        from_object = field["type"]["name"]
        # then we go over the types and find the object
        deep_selector_build(types, from_object)
      when "SCALAR"
        field["name"].as_s
      else
        ""
      end
    end

    private def deep_selector_build(types, from_object) : String
      types.as_a.each do |type|
        if type["name"] == from_object
          puts "Found related object! #{from_object}"
          selections = ""
          inner_fields = type["fields"]?.try &.as_a?
          next unless inner_fields
          inner_fields.each do |sub_field|
            next unless sub_field["type"]["kind"] == "SCALAR"
            selections += "#{sub_field["name"]} "
          end
          return selections.rstrip(" ")
        end
      end
      ""
    end

    private def build_args(args : Array(JSON::Any)) : String
      if args.empty?
        return ""
      end
      arguments = "("
      args.each do |arg|
        arg_name = arg["name"]?
        next unless arg_name
        arg_type = arg["type"]["name"].as_s?
        next unless arg_type
        value = case arg_type
                when .includes?("String")
                  "\\\"test\\\""
                when .includes?("Int")
                  "1"
                when .includes?("Boolean")
                  "true"
                when .includes?("Float")
                  "1.0"
                when .includes?("ID")
                  "\\\"#{UUID.random.to_s}\\\""
                else
                  "\\\"test\\\""
                end
        arguments += "#{arg_name}: #{value}, "
      end
      arguments = arguments.rstrip(", ") # Remove trailing comma and space
      # Add the closing parenthesis and bracket
      arguments += ")"
      if arguments == "()"
        return ""
      else
        arguments
      end
    end

    private def add_to_har(har : HAR::Log, operation_query : String, response : HTTP::Client::Response)
      # Har Request
      har_request = HAR::Request.new(
        url: @url.to_s,
        method: "POST",
        http_version: "HTTP/1.1"
      )
      har_request.post_data = HAR::PostData.new(text: "{\"query\": \"#{operation_query}\"}", mime_type: "application/json")
      # Create a new HAR entry for this operation
      har_request.headers << HAR::Header.new(name: "Content-Type", value: "application/json")

      # Har Response
      har_response = HAR::Response.new(
        status: response.status.code,
        status_text: "",
        http_version: "HTTP/1.1",
        content: HAR::Content.new(
          size: response.body.to_s.size,
          mime_type: "application/json",
          text: response.body.to_s
        ),
        redirect_url: ""
      )

      response.headers.each do |k, v|
        case v
        when String
          har_response.headers << HAR::Header.new(name: k, value: v)
        when Array
          v.each do |v2|
            har_response.headers << HAR::Header.new(name: k, value: v2)
          end
        end
      end

      # Build Entry
      har.entries << HAR::Entry.new(
        request: har_request,
        response: har_response,
        time: 0.0,
        timings: HAR::Timings.new(
          send: 0.0,
          wait: 0.0,
          receive: 0.0
        ),
      )
    end
  end
end

url = ARGV[0]?
if url.nil?
  puts "Please provide a URL to the GraphQL endpoint".colorize(:red)
  exit 1
end

begin
  parsed = URI.parse(url)
  conv = Harph::Convert.new(parsed)
  conv.to_har
rescue e : Exception
  puts "Invalid URL provided: #{e}".colorize(:red)
  exit 1
end


