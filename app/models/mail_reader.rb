# TODOs:
# * Update existing issues
# * Refactor
class MailReader < ActionMailer::Base

  def receive(email)
    
    html_body = email.body.split(/<(HTML|html)/)[0]
    unless html_body.nil?
      body = html_body
    else
      body = email.body
    end
    
    # find project
    project_name = line_match(body, "Project", '')
    @@project = Project.find_by_name project_name, :include => :enabled_modules , :conditions => "enabled_modules.name='ticket_emailer'"
    
    if @@project.nil?
      RAILS_DEFAULT_LOGGER.debug "Project not found with a name of #{project_name} with the ticket_emailer enabled"
      return false
    end
    
    # If the email exists for a user in the current project,
    # use that user as the author.  Otherwise, abort
    author = User.find(:first, :conditions => { :mail => @@from_email, "members.project_id" => @@project.id }, :select=>"users.id", :joins=>"inner join members on members.user_id = users.id")
        
    if author.nil?
      RAILS_DEFAULT_LOGGER.debug "Author not found with the email of #{@@from_email}"
      return false      
    end
    
    #check if the email subject includes an issue id
    issue_id = email.subject.scan(/#(\d+)/).flatten
 
    #if issue_id found in email subject then try to find corresponding issue
    unless issue_id.empty?
      begin
        issue = Issue.find(issue_id[0])
      rescue
        RAILS_DEFAULT_LOGGER.debug "Issue #{issue_id[0]} not found"
      end
    end
    
    assigned_email = line_match(body, "Assign", '')
    unless assigned_email.nil?
      assigned_to = User.find(:first, :conditions => { :mail => assigned_email, "members.project_id" => @@project.id }, :joins=>"inner join members on members.user_id = users.id")
    end                           
    unless assigned_to.nil?
      RAILS_DEFAULT_LOGGER.debug "Ticket assigned to #{assigned_to.mail}"
    end
    
    # TODO: Refactor priorities
    priorities = Enumeration.get_values('IPRI')
    @DEFAULT_PRIORITY = priorities[0]
    @PRIORITY_MAPPING = {}
    priorities.each { |prio| @PRIORITY_MAPPING[prio.name] = prio }
    
    @DEFAULT_TRACKER = @@project.trackers.find_by_position(1) || Tracker.find_by_position(1)
    
    #Find attributes and assign defaults if they don't exist for new issues.
    if issue.nil?                     
      status = IssueStatus.find_by_name(line_match(body, "Status", '')) || IssueStatus.default
      priority = @PRIORITY_MAPPING[line_match(body, "Priority", '')] || @DEFAULT_PRIORITY
      tracker = @@project.trackers.find_by_name(line_match(body, "Tracker", '')) || @DEFAULT_TRACKER
    else
      #Find attributes for existing issues.
      status = IssueStatus.find_by_name(line_match(body, "Status", ''))
      priority = @PRIORITY_MAPPING[line_match(body, "Priority", '')]
      tracker = @@project.trackers.find_by_name(line_match(body, "Tracker", ''))
    end
    
    category = @@project.issue_categories.find_by_name(line_match(body, "Category", ''))
    
    if issue.nil?
       RAILS_DEFAULT_LOGGER.debug "Creating new issue"
      # TODO: Description is greedy and will take other keywords after itself.  e.g.
      #
      #   Description:
      #   Stage 2
      #   Descrip is here
      #   
      #   Subject: Issue subject
      # #=> Description has 'Subject' in it
      issue = Issue.create(
          :subject => line_match(body, "Subject", email.subject),
          :description => block_match(body, "Description", ''),
          :priority_id => priority.id,
          :project_id => @@project.id,
          :tracker => tracker,
          :author_id => author.id,
          :assigned_to => assigned_to,
          :category => category,
          :status => status
      )
      Mailer.deliver_issue_add(issue) if Setting.notified_events.include?('issue_added')
    else

      #using the issue found from subject, create a new note for the issue
      ic = Iconv.new('UTF-8', 'UTF-8')
      RAILS_DEFAULT_LOGGER.debug "Issue ##{issue.id} exists adding comment"
      journal = Journal.new(:notes => ic.iconv(block_match(body, "Description", '')),
                     :journalized => issue,
                     :user_id => author.id);
      if(!journal.save)
         RAILS_DEFAULT_LOGGER.debug "Failed to add comment"
         return false
      end
      
      unless priority.nil?
        unless issue.priority_id == priority.id
          JournalDetail.create(:journal_id => journal.id, :property => 'attr', :prop_key => 'priority_id', :old_value => issue.priority_id, :value => priority.id)
          issue.update_attributes(:priority_id => priority.id)
        end
      end
      unless tracker.nil?
        unless issue.tracker_id == tracker.id
          JournalDetail.create(:journal_id => journal.id, :property => 'attr', :prop_key => 'tracker_id', :old_value => issue.tracker.name, :value => tracker.name)
          issue.update_attributes(:tracker_id => tracker.id)
        end
      end
      unless assigned_to.nil?
        unless issue.assigned_to_id == assigned_to.id
          JournalDetail.create(:journal_id => journal.id, :property => 'attr', :prop_key => 'assigned_to_id', :old_value => issue.assigned_to_id, :value => assigned_to.id)
          issue.update_attributes(:assigned_to_id => assigned_to.id)
        end
      end
      unless category.nil?
        unless issue.category_id == category.id
          JournalDetail.create(:journal_id => journal.id, :property => 'attr', :prop_key => 'category_id', :old_value => issue.category_id, :value => category.id)
          issue.update_attributes(:category_id => category.id)
        end
      end
      unless status.nil?
        unless issue.status_id == status.id
          JournalDetail.create(:journal_id => journal.id, :property => 'attr', :prop_key => 'status_id', :old_value => issue.status_id, :value => status.id)
          issue.update_attributes(:status_id => status.id)
        end
      end
      
      Mailer.deliver_issue_edit(journal) if Setting.notified_events.include?('issue_updated')

    end
    
    if email.has_attachments?
        for attachment in email.attachments        
            Attachment.create(:container => issue, 
                :file => attachment,
                :description => line_match(body, "Attachment", ''),
                :author => author
            )
        end
    end

  end
  
  def self.check_mail
  
     begin
       require 'net/imap'
     rescue LoadError
       raise RequiredLibraryNotFoundError.new('NET::Imap could not be loaded')
     end

     @@config_path = (RAILS_ROOT + '/config/emailer.yml')
     
    # Load the configuration file
    @@config = YAML.load_file(@@config_path)
    
    for num in (1..@@config['num_email_servers'])
       imap = Net::IMAP.new(@@config["email_server#{num}"], port=@@config["email_port#{num}"], usessl=@@config["use_ssl#{num}"])

       imap.login(@@config["email_login#{num}"], @@config["email_password#{num}"])
       imap.select(@@config["email_folder#{num}"])  

       imap.search(['ALL']).each do |message_id|
         RAILS_DEFAULT_LOGGER.debug "Receiving message #{message_id}"
         msg = imap.fetch(message_id,'RFC822')[0].attr['RFC822']
         @@from_email = from_email_address(imap, message_id)
         MailReader.receive(msg)          
         #Mark message as deleted and it will be removed from storage when user session closd
         imap.store(message_id, "+FLAGS", [:Deleted])
         # tell server to permanently remove all messages flagged as :Deleted
         imap.expunge()
       end
     end
     
    #imap = Net::IMAP.new(@@config[:email_server], port=@@config[:email_port], usessl=@@config[:use_ssl])
             
    #imap.login(@@config[:email_login], @@config[:email_password])
    #imap.select(@@config[:email_folder])  
                     
 #   imap.search(['ALL']).each do |message_id|
#      RAILS_DEFAULT_LOGGER.debug "Receiving message #{message_id}"
#      msg = imap.fetch(message_id,'RFC822')[0].attr['RFC822']
#      @@from_email = from_email_address(imap, message_id)
#      MailReader.receive(msg)          
#      #Mark message as deleted and it will be removed from storage when user session closd
#      imap.store(message_id, "+FLAGS", [:Deleted])
#      # tell server to permanently remove all messages flagged as :Deleted
#      imap.expunge()
#    end
  end
  
  def self.from_email_address(imap, msg_id) 
    env = imap.fetch(msg_id, "ENVELOPE")[0].attr["ENVELOPE"]
    mailbox = env.from[0].mailbox
    host    = env.from[0].host
    from = "#{mailbox}@#{host}"
  end
  
  private
  
  # Taken from bugmail.rb
  def match(msg, regex, default)
    if((msg =~ regex))
      return $1.strip
    end
    return default
  end

  def line_match(msg, label, default)
    return match(msg, /^#{label}:[ \t]*(.*)$/, default)
  end

  def block_match(msg, label, default)
    return match(msg, /^#{label}:[ \t]*(.*)$/m, default)
  end

end
