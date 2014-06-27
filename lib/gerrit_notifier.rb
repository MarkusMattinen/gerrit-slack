class GerritNotifier
  @@buffer = {}
  @@channel_config = {}

  def self.start!
    @@channel_config = YAML.load(File.read('config/channels.yml'))
    start_buffer_daemon
    listen_for_updates
  end

  def self.notify(update, msg)
    update.channels(@@channel_config).each do |channel|
      channel = "##{channel}"
      add_to_buffer channel, msg
    end
  end

  def self.notify_user(user, msg)
    channel = "@#{user}"
    add_to_buffer channel, msg
  end

  def self.add_to_buffer(channel, msg)
    @@buffer[channel] ||= []
    @@buffer[channel] << msg
  end

  def self.start_buffer_daemon
    # post every X seconds rather than truly in real-time to group messages
    # to conserve slack-log
    Thread.new do
      slack_config = YAML.load(File.read('config/slack.yml'))['slack']

      while true
        if @@buffer == {}
          puts "[#{Time.now}] Buffer is empty"
        else
          puts "[#{Time.now}] Current buffer:"
          ap @@buffer
        end

        if @@buffer.size > 0
          @@buffer.each do |channel, messages|
            notifier = Slack::Notifier.new slack_config['team'], slack_config['token']
            notifier.ping(messages.join("\n\n"),
              channel: channel,
              username: 'gerrit',
              icon_emoji: ':dragon_face:',
              link_names: 1
            )
          end
        end

        @@buffer = {}

        sleep 15   # could up this to every minute or two instead
      end
    end
  end

  def self.listen_for_updates
    stream = YAML.load(File.read('config/gerrit.yml'))['gerrit']['stream']
    puts "Listening to stream via #{stream}"
    
    IO.popen(stream).each do |line|
      update = Update.new(line)

      ap update.json
      puts update.raw_json

      if update.channels(@@channel_config).size == 0
        puts "No subscribers, skipping."
        next
      end

      # Jenkins update
      if update.jenkins?
        if update.build_successful? && !update.wip?
          notify update, "#{update.commit} *passed* Jenkins and is ready for *code review*"
        elsif update.build_failed?
          notify_user update.owner, "#{update.commit_without_owner} *failed* on Jenkins"
        end
      end

      # Code review +2
      if update.code_review_approved?
        notify update, "#{update.author} has *+2'd* #{update.commit}: ready for *QA*"
      end

      # Code review +1
      if update.code_review_tentatively_approved?
        notify update, "#{update.author} has *+1'd* #{update.commit}: needs another set of eyes for *code review*"
      end

      # QA/Product
      if update.qa_approved? && update.product_approved?
        notify update, "#{update.author} has *QA/Product-approved* #{update.commit}! :mj: :victory:"
      elsif update.qa_approved?
        notify update, "#{update.author} has *QA-approved* #{update.commit}! :mj:"
      elsif update.product_approved?
        notify update, "#{update.author} has *Product-approved* #{update.commit}! :victory:"
      end

      # Rejected by any reviewer
      if update.code_review_rejected? || update.qa_rejected? || update.product_rejected?
        notify update, "#{update.author} has *rejected* #{update.commit}"
      end

      # New comment added
      if update.comment_added? && update.human? && update.comment != ''
        notify update, "#{update.author} has left comments on #{update.commit}: \"#{update.comment}\""
      end

      # Merged
      if update.merged?
        notify update, "#{update.commit} was merged! \\o/ :yuss: :dancing_cool:"
      end
    end
  end
end