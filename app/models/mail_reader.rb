# TODOs:
# * Update existing issues
# * Don't require project specific setup
# * Add Tracker
# * Add Categry
class MailReader < ActionMailer::Base

  def receive(email)         
    # If the email exists for a user in the current project,
    # use that user as the author.  Otherwise, use the first
    # user that is returned from the Member model
    author = User.find_by_mail @@from_email, :select=>"users.id", :joins=>"inner join members on members.user_id = users.id",
                              :conditions=>["members.project_id=?", @@project.id]
    
    if author.nil?
       author_id = (Member.find_by_project_id @@project.id).id
    else
        author_id = author.id
    end
    
    status = IssueStatus.find_by_name(line_match(email.body, "Status", '')) || IssueStatus.default
    
    # TODO: Refactor priorities
    priorities = Enumeration.get_values('IPRI')
    @DEFAULT_PRIORITY = priorities[0]
    @PRIORITY_MAPPING = {}
    priorities.each { |prio| @PRIORITY_MAPPING[prio.name] = prio }
    priority = @PRIORITY_MAPPING[line_match(email.body, "Priority", '')] || @DEFAULT_PRIORITY
    
    # TODO: Description is greedy and will take other keywords after itself.  e.g.
    #
    #   Description:
    #   Stage 2
    #   Descrip is here
    #   
    #   Subject: Issue subject
    # #=> Description has 'Subject' in it
    issue = Issue.create(
        :subject => line_match(email.body, "Subject", email.subject),
        :description => block_match(email.body, "Description", ''),
        :priority => priority,
        :project_id => @@project.id,
        :tracker_id => 3,
        :author_id => author_id,
        :status => status
    )
    
    if email.has_attachments?
        for attachment in email.attachments        
            Attachment.create(:container => issue, 
                                  :file => attachment,
                                  :description => "",
                                  :author_id => 2)
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
     
     # Cycle through all of the projects created in the yaml file
     YAML.load_file(@@config_path).keys.each do |project_name|
     
        #Find the project based off the name in the YAML if the emailer is enabled in Redmine
        @@project = Project.find_by_name project_name, :include=>:enabled_modules , :conditions=>"enabled_modules.name='ticket_emailer'"

        unless @@project.nil?
            @@config = YAML.load_file(@@config_path)[project_name].symbolize_keys
                 
            imap = Net::IMAP.new(@@config[:email_server], port=@@config[:email_port], usessl=@@config[:use_ssl])
             
            imap.login(@@config[:email_login], @@config[:email_password])
            imap.select(@@config[:email_folder])  
                     
            imap.search(['ALL']).each do |message_id|
              RAILS_DEFAULT_LOGGER.debug "Receiving message #{message_id}"
              msg = imap.fetch(message_id,'RFC822')[0].attr['RFC822']
              @@from_email = from_email_address(imap, message_id)
              MailReader.receive(msg)          
              #Mark message as deleted and it will be removed from storage when user session closd
####              imap.store(message_id, "+FLAGS", [:Deleted])
            end
            # tell server to permanently remove all messages flagged as :Deleted
####            imap.expunge()
        end
    end
  end
  
  def attach_files(obj, attachment)
    attached = []
    user = User.find 2
    if attachment && attachment.is_a?(Hash)
        file = attachment['file']
            Attachment.create(:container => obj, 
                                  :file => file,
                                  :author => user)
        attached << a unless a.new_record?
    end
    attached
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
