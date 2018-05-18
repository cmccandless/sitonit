require 'sinatra'
require 'json'
require 'octokit'
require 'date'

ACCESS_TOKEN = ENV['SITONIT_ACCESS_TOKEN']
# Time until mergable in minutes
TIME_TO_MERGE_MINUTES = 2
TIME_TO_MERGE_DAYS = TIME_TO_MERGE_MINUTES.to_f / 60 / 24

Signal.trap('INT') {
    @running = false
    puts 'Exiting...'
    exit
}

Signal.trap('TERM') {
    @running = false    
    puts 'Exiting...'
    exit
}

before do
    @client ||= Octokit::Client.new(:access_token => ACCESS_TOKEN)
    @running = true
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
        context = "continuous-integration/SitOnIt"
        created = DateTime.strptime(pull_request['created_at'])
        target = created + TIME_TO_MERGE_DAYS
        while @running
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
            @client.create_status(
                pull_request['base']['repo']['full_name'],
                pull_request['head']['sha'],
                'pending',
                :context => context,
                :description => description,
            )
            puts "#{pull_request['base']['repo']['full_name']}/#{pull_request['head']['sha']}: #{description}"
            sleep(30)
        end
        description = "This PR is old enough to merge."
        @client.create_status(
            pull_request['base']['repo']['full_name'],
            pull_request['head']['sha'],
            'success',
            :context => context,
            :description => description,
        )
        puts description
      end
  end
  