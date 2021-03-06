require "io/console"

require "rubygems"
require "json"
require "httparty"

require "fileutils"
require "zip"

FORMATS = %w(aiff flac mp3 wav)
YESNO = %w(y n)

HR = "\n================================================================================\n"

MAX_TRIES = 10

class DripFM
  include HTTParty
  base_uri "https://drip.kickstarter.com"

  # GETTERS / SETTERS
  # Cookies
  def cookies(); @cookies end
  def cookies=(c); @cookies = c end
  # Current user
  def user(); @user end
  def user=(u); @user = u end
  # Login data
  def login_data(); @login_data end
  def login_data=(ld); @login_data = ld end
  # Chosen label
  def label(); @label end
  def label=(l); @label = l end
  # Releases
  def releases(); @releases end
  def releases=(r); @releases = r end
  # Settings
  def settings(); @settings end
  def settings=(s) @settings = s end

  # HELPERS
  def choose(prompt, choices, options={})
    choices_str = choices.join '/'
    choices_str = options[:choices_str] if options[:choices_str]

    choices_stringified = choices.map { |choice| choice.to_s }

    choice = ""
    while !(choices_stringified.include? choice) do
      print "#{prompt} (#{choices_str}): "
      choice = gets.chomp.downcase
    end

    if options[:boolean]
      return choice == "y"
    else
      return choice
    end
  end

  def send_login_request
    login_req = self.class.post "/api/users/login",
      body: @login_data.to_json,
      :headers => { 'Content-Type' => 'application/json', 'Accept' => 'application/json'}

    response_code = login_req.response.code.to_i

    if response_code < 400
      @cookies = login_req.headers["Set-Cookie"]
      @user = JSON.parse(login_req.body)
    end

    return response_code
  end

  # Safe filename without illegal characters
  def safe_filename(filename)
    out = filename.gsub(/[\x00:\*\?\"<>\|]/, ' ').strip
    out.encode! "US-ASCII", out.encoding, replace: "_"
    out
  end

  def safe_dirname(dirname)
    out = dirname.gsub(/[\x00:\\\/\*\?\"<>\|]/, ' ').strip
    out.encode! "US-ASCII", out.encoding, replace: "_"
    out
  end

  # Label directory name
  def label_dirname(label=@label)
    dirname = label["creative"]["service_name"]
    dirname = dirname[0..40].strip

    safe_dirname(dirname)
  end

  # Returns the zip file name for a release
  def zip_filename(release)
    if release['slug'] && release['slug'].length > 0
      filename = release['slug'][0..40].strip
    else
      filename = release['id'].to_s
    end

    "#{label_dirname}/#{safe_filename(filename)}.zip"
  end

  # Returns the unpack directory name for a release
  def unpack_dirname(release)
    artist_dir = safe_dirname release["artist"][0..40].strip
    title_dir = safe_dirname release["title"][0..40].strip

    "#{label_dirname}/#{artist_dir}/#{title_dir}"
  end

  # The constructor
  def initialize(e, p)
    @settings = {}
    @login_data = { email: e, password: p }

    login_response = send_login_request

    if login_response >= 400
      puts "FAIL: Wrong login data according to drip :("
      abort
    end

    puts "\n\n"
    puts "Login success!"

    # Greet this dawg!
    puts "Hi, #{@user['firstname']} #{@user['lastname']}! :)\n\n"

    # DO THINGS
    @settings = ask_for_settings
    puts HR
    @label = choose_label
    puts HR
    @releases = set_releases

    grab_releases
  end

  # Ask the user for settings for this run
  def ask_for_settings
    format = choose "Which format do you want to download the releases in?", FORMATS
    puts "\tFLAC is superior, you Apple loving hipster. But I'll grab AIFF for you anyways." if format == "aiff"

    unpack = choose "Do you want to automatically unpack the downloaded releases?", YESNO,
      boolean: true

    ask_for_download = choose "Do you want to confirm each release download?", YESNO,
      boolean: true

    { format: format, unpack: unpack, ask_for_download: ask_for_download }
  end

  # Ask the user to choose a label
  def choose_label
    labels = @user["memberships"] + @user["historical_memberships"]

    puts "Your subscriptions are:"
    labels.each_index do |i|
      puts "   #{i+1}) #{labels[i]['creative']['service_name']}"
    end

    puts

    label_choices = (1..labels.length).to_a
    label_choice = choose "From which one do you wanna grab some sick music?", label_choices,
      choices_str: "choose by number"

    label = labels[label_choice.to_i - 1] # substract 1 for array index
    puts "Alright, we're gonna fetch some sick shit from #{label["creative"]["service_name"]}!"

    FileUtils.mkdir_p label_dirname(label)

    label
  end

  # Set the @releases object from the @label object data.
  def set_releases
    slug = @label["creative"]["slug"]

    releases = []
    releases_part_index = 1
    releases_part = nil

    while releases_part != []
      releases_req = self.class.get "/api/creatives/#{slug}/releases?page=#{releases_part_index}",
        headers: { "Cookie" => @cookies }

      releases_part = JSON.parse(releases_req.body)

      releases += releases_part.reject { |r| !r["unlocked"] }
      releases_part_index += 1
    end

    releases
  end

  # Fetch and save the releases.
  def grab_releases
    puts "Let's see here..."
    puts "Found #{@releases.count} releases that you can download from this drip."
    puts

    @releases.each do |release|
      artist = release['artist']
      title = release['title']

      puts "We've got \"#{title}\" by #{artist}."

      dirname = unpack_dirname(release)
      zipfile = zip_filename(release)

      if (File.size?(zipfile) \
        or (
          File.directory?(dirname) \
          and not (
            (Dir.entries(dirname) - %w{ . .. Thumbs.db .DS_Store }).empty?
          )
        )
      )
        puts "It seems you've already got this release. Skipping."
        puts "========"
        puts
      else
        if @settings[:ask_for_download]
          fetch_current = choose "Wanna grab that?", YESNO,
            boolean: true
        end

        if fetch_current || !@settings[:ask_for_download]
          fetch_release(release)
        end
      end
    end
  end

  def fetch_release(release, trycount=0, chosen_format=nil)
    release_url = "/api/creatives/#{@label['creative']['slug']}/releases/#{release['id']}"
    formats = JSON.parse(self.class.get(release_url + "/formats").body)

    chosen_format ||= @settings[:format]
    if !(formats.include? chosen_format)
      puts "[!] This release was not published with your preferred format."
      chosen_format = choose "[!] Please choose an available format", formats
    end

    url = "/api/creatives/#{@label['creative_id']}"
    url += "/releases/#{release['id']}"
    url += "/download?release_format=#{chosen_format}"

    filename = zip_filename(release)

    if trycount <= 0
      puts "Saving to \"#{filename}\"..."
      puts "Please stand by while this release is being fetched..."
    end

    success = false

    begin
      file_request = self.class.get url,
        headers: { "Cookie" => @cookies }
    rescue => e
      puts "[!] An error occurred while downloading #{release['title']}: \"#{e.message}\""

      fetch_retry = choose "[!] Wanna retry?", YESNO,
        boolean: true

      fetch_release(release, trycount, chosen_format) if fetch_retry
      return
    end

    if file_request.code.to_i < 400
      File.open(filename, "wb") do |f|
        f.write file_request.parsed_response
      end

      unpack_release(release) if @settings[:unpack]

      puts "Done. :)"
      puts "========"
      puts
    else
      if trycount < MAX_TRIES
        send_login_request
        fetch_release(release, trycount + 1, chosen_format)
      else
        puts "[!] Release could not be fetched. I'm terribly sorry :("
        fetch_retry = choose "[!] Wanna retry?", YESNO,
          boolean: true

        fetch_release(release, 0, chosen_format) if fetch_retry
      end
    end

    if @settings[:unpack]
      FileUtils.rm filename, force: true # remove zip after unpacking or if fetching fails
    end
  end

  def unpack_release(release)
    puts "Unpacking #{release['title']}..."

    filename = zip_filename(release)

    if File.exist? filename
      dirname = unpack_dirname(release)
      FileUtils.mkdir_p(dirname)

      begin
        Zip::File.open(filename) do |zipfile|
          zipfile.each do |file|
            target_filename = safe_filename("#{dirname}/#{file.name}")
            file.extract target_filename
          end
        end
      rescue Zip::Error => e
        puts "[!] Something went wrong while unpacking #{release['title']}: \"#{e.message}\""

        retry_unpack = choose "[!] Wanna retry?", YESNO,
          boolean: true

        if retry_unpack
          unpack_release(release)
        end
      end
    else
      puts "Source zip file could not be found! Release could not be unpacked :("
    end
  end

end

### MAIN CODE
puts "\t\t    +-------------------------------------+"
puts "\t\t    | WELCOME TO THE DRIP DOWNLOADER 2014 |"
puts "\t\t    +-------------------------------------+"
puts "\n"
puts "       \"Man this is awesome, I can feel the releases raining down on me\""
puts "           - You, #{Time.now.year}"

puts HR

puts "Please enter your login info!"
print "Email: "
email = gets.chomp
print "Password: "
password = STDIN.noecho(&:gets).chomp

drip = DripFM.new(email, password)

puts "                                   ALL DONE!"
puts "                         Thanks for using this tool <3"
