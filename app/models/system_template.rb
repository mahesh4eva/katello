#
# Copyright 2011 Red Hat, Inc.
#
# This software is licensed to you under the GNU General Public
# License as published by the Free Software Foundation; either version
# 2 of the License (GPLv2) or (at your option) any later version.
# There is NO WARRANTY for this software, express or implied,
# including the implied warranties of MERCHANTABILITY,
# NON-INFRINGEMENT, or FITNESS FOR A PARTICULAR PURPOSE. You should
# have received a copy of GPLv2 along with this software; if not, see
# http://www.gnu.org/licenses/old-licenses/gpl-2.0.txt.

require 'util/package_util'
require 'active_support/builder' unless defined?(Builder)

class ParentTemplateValidator < ActiveModel::Validator
  def validate(record)
    #check if the parent is from
    if not record.parent.nil?
      record.errors[:parent] << _("Template can have parent templates only from the same environment") if record.environment_id != record.parent.environment_id
    end
  end
end

class SystemTemplate < ActiveRecord::Base
  #include Authorization
  include LazyAccessor
  include AsyncOrchestration

  #has_many :products
  belongs_to :environment, :class_name => "KTEnvironment", :inverse_of => :system_templates
  has_and_belongs_to_many :changesets

  scoped_search :on => :name, :complete_value => true, :rename => :'system_template.name'

  validates_presence_of :name
  validates_uniqueness_of :name, :scope => :environment_id
  validates_with ParentTemplateValidator

  belongs_to :parent, :class_name => "SystemTemplate"
  has_and_belongs_to_many :products, :uniq => true
  has_many :packages, :class_name => "SystemTemplatePackage", :inverse_of => :system_template, :dependent => :destroy
  has_many :package_groups, :class_name => "SystemTemplatePackGroup", :inverse_of => :system_template, :dependent => :destroy
  has_many :pg_categories, :class_name => "SystemTemplatePgCategory", :inverse_of => :system_template, :dependent => :destroy

  attr_accessor :host_group
  lazy_accessor :parameters, :initializer => lambda { init_parameters }, :unless => lambda { false }

  before_validation :attrs_to_json
  after_initialize :save_content_state
  before_save :update_revision
  before_destroy :check_children


  def init_parameters
    ActiveSupport::JSON.decode((self.parameters_json or "{}"))
  end


  def import tpl_file_path
    Rails.logger.info "Importing into template #{name}"

    file = File.open(tpl_file_path,"r")
    content = file.read
    self.string_import content

  ensure
    file.close
  end


  def string_import content
    json = ActiveSupport::JSON.decode(content)

    if not json["parent"].nil?
      self.parent = SystemTemplate.find(:first, :conditions => {:name => json["parent"], :environment_id => self.environment_id})
    end

    self.revision = json["revision"]
    self.description = json["description"]
    self.name = json["name"] if json["name"]
    self.save!
    json["products"].each {|p| self.add_product(p) } if json["products"]
    json["packages"].each {|p| self.add_package(p) } if json["packages"]
    json["package_groups"].each {|pg| self.add_package_group(pg) } if json["package_groups"]
    json["package_group_categories"].each {|pgc| self.add_pg_category(pgc) } if json["package_group_categories"]

    json["parameters"].each_pair {|k,v| self.parameters[k] = v } if json["parameters"]
  end

  def export_as_hash
    tpl = {
      :name => self.name,
      :revision => self.revision,
      :packages => self.packages.map(&:nvrea),
      :products => self.products.map(&:name),
      :parameters => ActiveSupport::JSON.decode(self.parameters_json || "{}"),
      :package_groups => self.package_groups.map(&:name),
      :package_group_categories => self.pg_categories.map(&:name),
    }
    tpl[:description] = self.description if not self.description.nil?
    tpl[:parent] = self.parent.name if not self.parent.nil?
    tpl
  end

  def export_as_json
    self.export_as_hash.to_json
  end


  # Returns template in XML TDL format:
  # https://github.com/aeolusproject/imagefactory/blob/master/Documentation/TDL.xsd
  def export_as_tdl
    uebercert = { :cert => "", :key => "" }
    begin
      uebercert = Candlepin::Owner.get_ueber_cert(environment.organization.cp_key)
    rescue RestClient::ResourceNotFound => e
      Rails.logger.info "Uebercert for #{environment.organization.name} has not been generated. Using empty cert and key fields."
    end

    xm = Builder::XmlMarkup.new
    xm.instruct!
    xm.template {
      # mandatory tags
      xm.name self.name
      xm.os {
        xm.name "Fedora"
        xm.version "14"
        xm.arch "x86_64"
        xm.install("type" => "url") {
          xm.url "http://repo.fedora.org/f14/os"
        }
      }
      # optional tags
      xm.description self.description unless self.description.nil?
      xm.packages {
        self.packages.each { |p| xm.package "name" => p.package_name }
        # TODO package groups
      }
      xm.repositories {
        self.products.each do |p|
          pc = p.repos(self.environment).each do |repo|
            xm.repository("name" => repo.id) {
              xm.url repo.uri
              xm.persisted "No"
              xm.clientcert uebercert[:cert]
              xm.clientkey uebercert[:key]
            }
          end
        end
      }
    }
  end


  def add_package package_name
    if pack_attrs = Katello::PackageUtils.parse_nvrea_nvre(package_name)
      self.packages.create!(:package_name => pack_attrs[:name], :version => pack_attrs[:version], :release => pack_attrs[:release], :epoch => pack_attrs[:epoch], :arch => pack_attrs[:arch])
    else
      self.packages.create!(:package_name => package_name)
    end
  end


  def remove_package package_name
    if pack_attrs = Katello::PackageUtils.parse_nvrea_nvre(package_name)
      package = self.packages.find(:first, :conditions => {:package_name => pack_attrs[:name], :version => pack_attrs[:version], :release => pack_attrs[:release], :epoch => pack_attrs[:epoch], :arch => pack_attrs[:arch]})
    else
      package = self.packages.find(:first, :conditions => {:package_name => package_name})
    end
    self.packages.delete(package)
  end

  def add_product product_name
    product = self.environment.products.find_by_name(product_name)
    if product == nil
      raise Errors::TemplateContentException.new("Product #{product_name} not found in this environment.")
    elsif self.products.include? product
      raise Errors::TemplateContentException.new("Product #{product_name} is already present in the template.")
    end
    self.products << product
  end

  def remove_product product_name
    product = self.environment.products.find_by_name(product_name)
    self.products.delete(product)
  rescue ActiveRecord::RecordInvalid
    raise Errors::TemplateContentException.new("The environment still has content that belongs to product #{product_name}.")
  end

  def add_product_by_cpid cp_id
    product = self.environment.products.find_by_cp_id(cp_id)
    if product == nil
      raise Errors::TemplateContentException.new("Product #{cp_id} not found in this environment.")
    elsif self.products.include? product
      raise Errors::TemplateContentException.new("Product #{cp_id} is already present in the template.")
    end
    self.products << product
  end

  def remove_product_by_cpid cp_id
    product = self.environment.products.find_by_cp_id(cp_id)
    self.products.delete(product)
  rescue ActiveRecord::RecordInvalid
    raise Errors::TemplateContentException.new("The environment still has content that belongs to product #{cp_id}.")
  end

  def set_parameter key, value
    self.parameters[key] = value
  end

  def remove_parameter key
    if not self.parameters.has_key? key
      raise Errors::TemplateContentException.new("Parameter #{key} not found in the template.")
    end
    self.parameters.delete(key)
  end

  def add_package_group pg_name
    self.package_groups.create!(:name => pg_name)
  end

  def remove_package_group pg_name
    package_group = self.package_groups.where(:name => pg_name).first
    if package_group == nil
      raise Errors::TemplateContentException.new(_("Package group '%s' not found in this template.") % pg_name)
    end
    self.package_groups.delete(package_group)
  end

  def add_pg_category pg_cat_name
    self.pg_categories.create!(:name => pg_cat_name)
  end

  def remove_pg_category pg_cat_name
    pg_category = self.pg_categories.where(:name => pg_cat_name).first
    if pg_category == nil
      raise Errors::TemplateContentException.new(_("Package group category '%s' not found in this template.") % pg_cat_name)
    end
    self.pg_categories.delete(pg_category)
  end

  def to_json(options={})
     super(options.merge({
        :methods => [:products,
                     :packages,
                     :parameters,
                     :package_groups,
                     :pg_categories]
        })
     )
  end

  def get_promotable_packages from_env, to_env, tpl_pack
    if tpl_pack.is_nvr?
      #if specified by nvre, ensure the nvre is there, othervise promote it
      return [] if to_env.find_packages_by_nvre(tpl_pack.package_name, tpl_pack.version, tpl_pack.release, tpl_pack.epoch).length > 0
      from_env.find_packages_by_nvre(tpl_pack.package_name, tpl_pack.version, tpl_pack.release, tpl_pack.epoch)

    else
      #if specified by name, ensure any package with this name is in the next env. If not, promote the latest.
      return [] if to_env.find_packages_by_name(tpl_pack.package_name).length > 0
      from_env.find_latest_packages_by_name(tpl_pack.package_name)
    end
  end


  def promote from_env, to_env
    #TODO: promote parent templates recursively

    promote_products from_env, to_env
    promote_packages from_env, to_env
    promote_template from_env, to_env

    []
  end


  def get_clones
    Organization.find(self.environment.organization_id).environments.collect do |env|
      env.system_templates.where(:name => self.name_was)
    end.flatten(1)
  end


  #### Permissions
  def self.list_verbs global = false
    {
      :manage_all => N_("Manage All System Templates"),
      :read_all => N_("Read All System Templates")
   }.with_indifferent_access
  end

  def self.no_tag_verbs
    SystemTemplate.list_verbs.keys
  end

  def self.any_readable? org
    User.allowed_to?([:read_all, :manage_all], :system_templates, nil, org)

  end

  def self.readable? org
    User.allowed_to?([:read_all, :manage_all], :system_templates, nil, org)
  end

  def self.manageable? org
    User.allowed_to?([:manage_all], :system_templates, nil, org)
  end

  def readable?
    self.class.readable?(self.environment.organization)
  end


  protected

  def promote_template from_env, to_env
    #clone the template
    tpl_copy = to_env.system_templates.find_by_name(self.name)
    tpl_copy.delete if not tpl_copy.nil?
    self.copy_to_env to_env
  end

  def promote_products from_env, to_env
    #promote the product only if it is not in the next env yet
    async_tasks = []
    self.products.each do |prod|
      async_tasks += (prod.promote from_env, to_env) if not prod.environments.include? to_env
    end
    PulpTaskStatus::wait_for_tasks async_tasks
  end

  def promote_packages from_env, to_env
    pkgs_promote = {}
    self.packages.each do |tpl_pack|

      #get packages that need to be promoted
      #in case there are more suitable packages (eg. two latest packages in two different repos in one product) we try to promote them all
      packages = self.get_promotable_packages from_env, to_env, tpl_pack
      next if packages.empty?

      any_package_promoted = false
      packages.each do |p|
        p = p.with_indifferent_access

        #check if there's where to promote them
        repo = Repository.find_by_pulp_id(p[:repo_id])
        if repo.is_cloned_in? to_env
          #remember the packages in a hash, we add them all together in one time
          clone = repo.get_clone to_env
          pkgs_promote[clone] ||= []
          pkgs_promote[clone] << p[:id]
          any_package_promoted = true
        end
      end

      if not any_package_promoted
        #there wasn't any package that we could promote (either it's product or repo have not been promoted yet)
        packages.map{|p| p[:product_id]}.uniq.each do |product_id|
          #promote (or sync) the product
          prod = Product.find_by_cp_id product_id
          PulpTaskStatus::wait_for_tasks prod.promote(from_env, to_env)
        end
      end
    end

    #promote all collected packages
    pkgs_promote.each_pair do |repo, pkgs|
      repo.add_packages(pkgs)
    end
  end

  def get_inheritance_chain
    chain = [self]
    tpl = self
    while not tpl.parent.nil?
      chain << tpl.parent
      tpl = tpl.parent
    end
    chain.reverse
  end

  def copy_to_env env
    new_tpl = SystemTemplate.new
    new_tpl.environment = env
    new_tpl.string_import(self.export_as_json)
    new_tpl.save!
  end

  #TODO: to be deleted after we switch to save parameters in foreman
  def attrs_to_json
    self.parameters_json = self.parameters.to_json
  end

  def get_content_state
    content = self.export_as_hash
    content.delete(:name)
    content.delete(:description)
    content.delete(:revision)
    content
  end

  def save_content_state
    @old_content = self.get_content_state
  end

  def content_changed?
    old_content_json     = @old_content.to_json
    current_content_json = self.get_content_state.to_json
    not (old_content_json.eql? current_content_json)
  end

  def update_revision
    self.revision = 1 if self.revision.nil?

    #increase revision number only on content attribute change
    if not self.new_record? and self.content_changed?
      self.revision += 1
      self.save_content_state
    end
  end

  def check_children
    children = SystemTemplate.find(:all, :conditions => {:parent_id => self.id})
    if not children.empty?
      raise Errors::TemplateContentException.new("The template has children templates.")
    end
  end

end
