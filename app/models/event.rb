class Event
  include UberRequestsConcern
  include Mongoid::Document
  include Geocoder::Model::Mongoid
  field :name, type: String
  field :depart_address, type: String
  field :arrival_address, type: String
  field :arrival_datetime, type: Time #UTC OR LOCAL TIME?
  field :ride_id, type: String # Product code
  field :ride_name, type: String #e.g. UberX
  field :ride_request_id, type: String #ID for the request
  field :surge_confirmation_id, type: String
  field :duration_estimate, type: Integer
  field :pickup_estimate, type: Integer
  field :arrival_coords, type: Array, default: [] #format: [lat, lng]
  field :depart_coords, type: Array, default: [] #format: [lat, lng]

  geocoded_by :geocode_user_addresses
  after_validation :geocode,
    :if => lambda{ |obj| obj.depart_address_changed? || obj.arrival_address_changed? }

  belongs_to :user

  def geocode_user_addresses
    depart_coords_hash = Geocoder.search(depart_address)[0].data['geometry']['location']
    puts depart_coords_hash
    arrival_coords_hash = Geocoder.search(arrival_address)[0].data['geometry']['location']
    puts arrival_coords_hash
    self.depart_coords[0] = depart_coords_hash['lat']
    self.depart_coords[1] = depart_coords_hash['lng']
    self.arrival_coords[0] = arrival_coords_hash['lat']
    self.arrival_coords[1] = arrival_coords_hash['lng']
  end

  ################ SCHEDULING BG JOBS AND CHECKING WHEN TO NOTIFY USER ####################

  def time_as_str
    self.arrival_datetime.strftime("%l:%M%P")
  end

  def estimated_duration
    self.duration_estimate + self.pickup_estimate
  end

  def update_estimate!
    puts "RIDE ESTIMATE RESPONSE:"
    p response = request_estimate_response(self)

    self.pickup_estimate = response['pickup_estimate']
    self.duration_estimate = (response['trip']['duration_estimate']/60.0).ceil
    self.save!

    puts "ESTIMATED DURATION: #{estimated_duration} (minutes)"

    response
  end

  def notification_buffer
    return 10.minutes
  end

  def time_to_notify_user
    self.arrival_datetime - estimated_duration - notification_buffer
  end

  def schedule_bg_job
    update_estimate!
    time_of_next_bg_job

    if time_to_notify_user < time_of_next_bg_job
      Resque.enqueue(NotifyUserWorker, self)
      puts "time to notify user is < time of next bg job; run NotifyUserWorker"
    elsif time_to_notify_user - time_of_next_bg_job < notification_buffer
      Resque.enqueue_at(time_to_notify_user, NotifyUserWorker, self)
      puts "time to notify user minus time of next bg job is < 10min; schedule NotifyUserWorker"
    else
      Resque.enqueue_at(time_of_next_bg_job, RequestEstimateWorker, self)
      puts "time to notify user is > 10min so schedule another RequestEstimateWorker"
    end

    puts "************************************"
    puts "Scheduled background job:"
    puts "Time of event: #{self.arrival_datetime}"
    puts "Time to notify user: #{time_to_notify_user}"
    puts "Time of next background job: #{time_of_next_bg_job}"
    puts "Current time: #{Time.current}"
    puts "************************************"
  end

  def time_of_next_bg_job
    if time_to_notify_user - Time.now > 180.minutes #more than 3 hours before need to notify
      return time_to_notify_user - 180.minutes
    else
      return time_to_notify_user - ((time_to_notify_user - Time.now) / 2)
    end
  end

  def update_ride_id!
    response = HTTParty.get("https://api.uber.com/v1/products",
      headers: {"Authorization" => "Bearer #{self.user.uber_access_token}",
      "scope" => "request",
      "Content-Type" => "application/json",
      },
      query: {
        # latitude: self.depart_lat,
        # longitude: self.depart_lon,
        latitude: self.depart_coords[0],
        longitude: self.depart_coords[1],
      }
    )

    response["products"].each do |product|
      return self.ride_id = product["product_id"] if self.ride_name == product["display_name"]
    end

    nil

  end

  ########### REQUESTING, CHECKING, UPDATING, CANCELLING RIDES ############
  def request_ride
    response = HTTParty.post("https://sandbox-api.uber.com/v1/requests",
      headers: {"Authorization" => "Bearer #{self.user.uber_access_token}",
      "scope" => "request",
      "Content-Type" => "application/json",
      },
      body: {
        product_id: self.ride_id,
        start_latitude: self.depart_coords[0],
        start_longitude: self.depart_coords[1],
        end_latitude: self.arrival_coords[0],
        end_longitude: self.arrival_coords[1]
      }.to_json
    )

    self.ride_request_id = response["request_id"]
    self.save!

    # add a twilio sms response to user saying the ride has been requested, that we will update them when it's accepted, and that they can cancel at any time by replying 'Abort'
    response #just for debugging
  end

  def change_ride_status(status) #For sandbox / testing only
    response = HTTParty.put("https://sandbox-api.uber.com/v1/sandbox/requests/#{self.ride_request_id}",
      headers: {"Authorization" => "Bearer #{self.user.uber_access_token}",
        "scope" => "request",
        "Content-Type" => "application/json",
      },
      body: {
          status: status #either use 'accepted' or 'no_drivers_available'
      }.to_json
    )

    response.code
  end

  def check_ride_status
    HTTParty.get("https://sandbox-api.uber.com/v1/requests/#{self.ride_request_id}",
      headers: {"Authorization" => "Bearer #{self.user.uber_access_token}",
        "scope" => "request",
        "Content-Type" => "application/json",
      }
    )
  end

  def cancel_ride
    response = HTTParty.delete("https://sandbox-api.uber.com/v1/requests/#{self.ride_request_id}",
      headers: {"Authorization" => "Bearer #{self.user.uber_access_token}",
        "scope" => "request",
        "Content-Type" => "application/json",
      }
    )

    response.code
  end

  ### TWILIO HELPER METHODS ###
  def send_twilio_message(message) #Send message to user via SMS
    client = Twilio::REST::Client.new ENV['TWILIO_ACCOUNT_SID'], ENV['TWILIO_AUTH_TOKEN']
    message = client.messages.create(
      :from => '+19255237514',
      :to => self.user.phone,
      :body => message,
      # :media_url => 'http://linode.rabasa.com/yoda.gif'
      # status_callback: request.base_url + '/twilio/status'
      )
  end

  def twilio_upcoming_event_notification #Initial notification asking user if they want to request a ride
    response = update_estimate!
    cost_range = response['price']['display']
    surge_multiplier = response['price']['surge_multiplier']
    surge_multiplier = 'none' if surge_multiplier == 1.0
    self.surge_confirmation_id = response['price']['surge_confirmation_id']
    surge_confirmation_href = response['price']['surge_confirmation_href']

    url = (surge_confirmation_href ? surge_confirmation_href : "#{Rails.env.development? ? "http://#{ENV['NGROK_KEY']}.ngrok.com" : root_url}/request_uber/?event_id=#{self.id.to_s}")

    message = "Upcoming event '#{self.name}' at #{self.time_as_str}. #{self.ride_name} estimated cost: #{cost_range}; pickup time: #{self.pickup_estimate}min; ride duration: #{self.duration_estimate}min. Surge multiplier: #{surge_multiplier}. Click to confirm: #{url}"

    send_twilio_message(message)
  end


end

# twilio_upcoming_event_notification
# twilio_ride_accepted_notification
# twilio_driver_arriving_notification
# twilio_driver_cancelled_notification
