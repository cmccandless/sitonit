require 'sinatra'
require 'json'
require 'octokit'
require 'date'
require 'yaml'
require 'base64'

set :port, ENV['PORT'].to_i

ACCESS_TOKEN = ENV['SITONIT_ACCESS_TOKEN']
# Default time until mergable in days
TIME_TO_MERGE_DAYS = 1.0
ENV = {'running': true}

Signal.trap('INT') {
    ENV[:running] = false
    puts 'Exiting...'
    exit
}

Signal.trap('TERM') {
    ENV[:running] = false
    puts 'Exiting...'
    exit
}

before do
    @running = true
    @client ||= Octokit::Client.new(:access_token => ACCESS_TOKEN)
end

get '/' do
    'SitOnIt!'
end

post '/event_handler' do
    @payload = JSON.parse(params[:payload])
  
    case request.env['HTTP_X_GITHUB_EVENT']
    when "pull_request"
        case @payload["action"]
        when "opened", "synchronize"
        process_pull_request(@payload["pull_request"])
        end
    end
  end
  
  helpers do
    def process_pull_request(pull_request)
        puts "Processing pull request..."
        puts Octokit.rate_limit
        context = "continuous-integration/SitOnIt"
        created = DateTime.strptime(pull_request['created_at'])
        repo = pull_request['base']['repo']['full_name']
        ref = pull_request['head']['sha']
        listing = @client.contents(repo, :ref => ref).collect { |f| f[:name] }
        target = created
        merge_on_fail = true
        if listing.include?('.sitonit.yml')
            puts "loading time from config..."
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
            puts "using default time"
            target = created + TIME_TO_MERGE_DAYS
        end
        puts "env: #{@env.to_s}"
        while ENV[:running]
            time_needed = target - DateTime.now
            puts "created_at: #{created}"
            puts "mergable at: #{target}"
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
        if ENV[:running] or merge_on_fail
            description = "This PR is old enough to merge."
            @client.create_status(repo, ref, 'success', :context => context, :description => description)
            puts description
        end
      end
  end
  