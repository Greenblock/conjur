# Stores a policy which has been applied to the database, along with metadata such as the role
# which submitted the policy.
# 
# A PolicyVersion is constructed on an existing 'policy' resource. PolicyVersion records are automatically
# assigned an incrementing +version+ number, just like Secrets.
#
# In addition to the 'policy' resource and the version, each PolicyVersion stores the following metadata:
#
# * +role+ the authenticated role who performed the policy load.
# * +created_at+ a timestamp.
# * +policy_text+ the text of the policy itself.
# * +policy_sha256+ the SHA-256 of the policy in hex digest form.
#
# The policy text is parsed when the PolicyVersion is validated. Parse errors are placed onto the 
# +#errors+ field, along with any other validation errors. The parsed policy is available through the
# +#records+ field.
#
# Except when loading the bootstrap policy, the policy statements that are submitted by the authenticated role
# are enclosed within a +!policy+ statement, so that all the statements in the policy are scoped by the enclosing id. 
# For example, suppose a PolicyVersion is being loaded for the policy +prod/myapp+. If policy being loaded
# contains a statement like +!layer+, then the layer id as loaded will be +prod/myapp+.
class PolicyVersion < Sequel::Model(:policy_versions)
  include HasId

  many_to_one :resource
  # The authenticated user who performs the policy load.
  many_to_one :role

  attr_accessor :parse_error, :policy_filename

  alias id resource_id
  alias current_user role
  alias policy resource
  alias policy= resource=

  def as_json options = {}
    super(options).tap do |response|
      response["id"] = response.delete("resource_id")
      %w(role).each do |field|
        write_id_to_json response, field
      end
    end
  end

  def bootstrap_policy?
    policy.kind == "policy" && policy.identifier == "bootstrap"
  end

  def validate
    super

    validates_presence [ :policy, :current_user, :policy_text ]

    try_load_records 

    if parse_error
      errors.add(:policy_text, parse_error.to_s)
    end
  end

  def before_save
    require 'digest'
    self.policy_sha256 = Digest::SHA256.hexdigest(policy_text)
  end


  def before_update
    raise Sequel::ValidationFailed, "Policy version cannot be updated once created"
  end

  def records
    try_load_records
    raise @parse_error if @parse_error
    @records
  end

  def policy_admin
    policy.owner
  end

  def try_load_records
    return if @records || @parse_error
    return unless policy_text

    begin
      records = Conjur::Policy::YAML::Loader.load(policy_text, policy_filename)
      records = wrap_in_policy records unless bootstrap_policy?
      @records = Conjur::Policy::Resolver.resolve records, account, policy_admin.id
    rescue
      $stderr.puts $!.message
      $stderr.puts $!.backtrace.join("  \n")
      @parse_error = $!
    end
  end

  # Wraps the input records in a policy whose id is the +policy+ id, and whose owner is the
  # +policy_admin+.
  def wrap_in_policy records
    policy_record = Conjur::Policy::Types::Policy.new policy.identifier
    policy_record.owner = Conjur::Policy::Types::Role.new(policy_admin.id)
    policy_record.account = policy.account
    policy_record.body = records
    [ policy_record ]
  end
end