require 'sinatra'
require 'json'
require 'octokit'
require 'date'
require 'yaml'
require 'base64'
require 'rest-client'
require 'openssl'
require 'jwt'

use Rack::Session::Cookie, :secret => rand.to_s()

set :port, ENV['PORT'].to_i

APP_ID = ENV['SITONIT_APP_ID']
ACCESS_TOKEN = ENV['SITONIT_ACCESS_TOKEN']
CLIENT_ID = ENV['SITONIT_CLIENT_ID']
CLIENT_SECRET = ENV['SITONIT_CLIENT_SECRET']
PRIVATE_KEY = OpenSSL::PKey::RSA.new(ENV['SITONIT_PRIVATE_KEY'])
# Default time until mergable in days
TIME_TO_MERGE_DAYS = 1.0
GLOBAL = Hash::new
GLOBAL[:running] = true

Signal.trap('INT') {
    GLOBAL[:running] = false
    puts 'Exiting...'
    exit
}

Signal.trap('TERM') {
    GLOBAL[:running] = false
    puts 'Exiting...'
    exit
}


before do
end

def authenticated?
    session[:access_token]
end

def authenticate!
    # client = Octokit::Client.new
    @client = Octokit::Client.new :client_id => CLIENT_ID, :client_secret => CLIENT_SECRET
    url = @client.authorize_url CLIENT_ID, :scope => 'public_repo'

    redirect url
end

get '/' do
    if !authenticated?
        authenticate!
    else
        access_token = session[:access_token]
        scopes = []
        @client = Octokit::Client.new :client_id => CLIENT_ID, :client_secret => CLIENT_SECRET

        begin
            @client.check_application_authorization access_token
        rescue => e
        # request didn't succeed because the token was revoked so we
        # invalidate the token stored in the session and render the
        # index page so that the user can start the OAuth flow again
            session[:access_token] = nil
            return authenticate!
        end

        @client = Octokit::Client.new :access_token => access_token
        data = client.user

        erb :email, {:locals => data.to_attrs}
    end
end

get '/callback' do
    session_code = request.env['rack.request.query_hash']['code']
    result = Octokit.exchange_code_for_token(session_code, CLIENT_ID, CLIENT_SECRET)
    session[:access_token] = result[:access_token]

    redirect '/'
end

post '/event_handler' do
    @payload = JSON.parse(request.body.read.to_s)

    case request.env['HTTP_X_GITHUB_EVENT']
    when "pull_request"
        case @payload["action"]
        when "opened", "synchronize"
        process_pull_request(@payload["pull_request"], @payload["installation"])
        end
    end
end

def github_client(installation_id)
    # TODO: drop this header once GitHub Integrations are officially released.
    accept = 'application/vnd.github.machine-man-preview+json'
  
    # Use a temporary JWT to get an access token, scoped to the integration's installation.
    headers = {'Authorization' => "Bearer #{new_jwt_token}", 'Accept' => accept}
    access_tokens_url = "/installations/#{installation_id}/access_tokens"
    access_tokens_response = Octokit::Client.new.post(access_tokens_url, headers: headers)
    access_token = access_tokens_response[:token]
  
    Octokit::Client.new(access_token: access_token)
  end
  
  # Generate the JWT required for the initial GitHub Integrations API handshake.
  # https://developer.github.com/early-access/integrations/authentication/#as-an-integration
  def new_jwt_token
    payload = {
      iat: Time.now.to_i,  # Issued at time.
      exp: (10 * 60) + Time.now.to_i,  # JWT expiration time.
      iss: APP_ID  # Integration's GitHub identifier.
    }
    JWT.encode(payload, PRIVATE_KEY, 'RS256')
  end

helpers do
    def process_pull_request(pull_request, installation)
        puts "Processing pull request..."
        @client = github_client(installation["id"])
        context = "continuous-integration/SitOnIt"
        created = DateTime.strptime(pull_request['created_at'])
        repo = pull_request['base']['repo']['full_name']
        ref = pull_request['head']['sha']
        listing = @client.contents(repo, :ref => ref).collect { |f| f[:name] }
        target = created
        merge_on_fail = true
        if listing.include?('.sitonit.yml')
            contents = @client.contents(repo, :ref => ref, :path => '.sitonit.yml')
            body = contents[:content]
            case contents[:encoding]
            when 'base64'
                body = Base64.decode64(body)
            else
                puts "unknown encoding #{contents[:encoding]}"
            end
            config = YAML.load(body)['config'][0]
            days = config.fetch('days', 0).to_f
            days += config.fetch('hours', 0).to_f / 24
            days += config.fetch('minutes', 0).to_f / 1440
            target = created + days
            merge_on_fail = config.fetch('merge_on_fail', true)
        else
            target = created + TIME_TO_MERGE_DAYS
        end
        while GLOBAL[:running]
            time_needed = target - DateTime.now
            # puts "created_at: #{created}"
            # puts "mergable at: #{target}"
            break if time_needed <= 0
            units = "days"
            if time_needed < 1
                time_needed *= 24
                units = "hours"
            end
            if time_needed < 1
                time_needed *= 60
                units = "minutes"
            end
            description = "This PR needs #{time_needed.round(0)} more #{units}."
            @client.create_status(repo, ref, 'pending', :context => context, :description => description)
            puts "#{repo}/#{pull_request['head']['sha']}: #{description}"
            sleep(30)
        end
        if GLOBAL[:running] or merge_on_fail
            description = "This PR is old enough to merge."
            @client.create_status(repo, ref, 'success', :context => context, :description => description)
            puts description
        end
    end
end
