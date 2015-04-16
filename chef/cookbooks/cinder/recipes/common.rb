# Copyright 2012 Dell, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Cookbook Name:: cinder
# Recipe:: common
#


if node[:cinder][:use_gitrepo]
  cinder_path = "/opt/cinder"
  venv_path = node[:cinder][:use_virtualenv] ? "#{cinder_path}/.venv" : nil
  venv_prefix = node[:cinder][:use_virtualenv] ? ". #{venv_path}/bin/activate &&" : nil

  pfs_and_install_deps "cinder" do
    wrap_bins [ "cinder-rootwrap", "cinder" ]
    path cinder_path
    virtualenv venv_path
  end

  create_user_and_dirs "cinder" do
    user_name node[:cinder][:user]
  end

  execute "cp_policy.json_#{@cookbook_name}" do
    command "cp #{cinder_path}/etc/cinder/policy.json /etc/cinder/"
    creates "/etc/cinder/policy.json"
  end

  template "/etc/sudoers.d/cinder-rootwrap" do
    source "cinder-rootwrap.erb"
    mode 0440
    variables(:user => node[:cinder][:user])
  end

  bash "deploy_filters_#{@cookbook_name}" do
    cwd cinder_path
    code <<-EOH
    ### that was copied from devstack's stack.sh
    if [[ -d $CINDER_DIR/etc/cinder/rootwrap.d ]]; then
        # Wipe any existing rootwrap.d files first
        if [[ -d $CINDER_CONF_DIR/rootwrap.d ]]; then
            rm -rf $CINDER_CONF_DIR/rootwrap.d
        fi
        # Deploy filters to /etc/cinder/rootwrap.d
        mkdir -m 755 $CINDER_CONF_DIR/rootwrap.d
        cp $CINDER_DIR/etc/cinder/rootwrap.d/*.filters $CINDER_CONF_DIR/rootwrap.d
        chown -R root:root $CINDER_CONF_DIR/rootwrap.d
        chmod 644 $CINDER_CONF_DIR/rootwrap.d/*
        # Set up rootwrap.conf, pointing to /etc/cinder/rootwrap.d
        cp $CINDER_DIR/etc/cinder/rootwrap.conf $CINDER_CONF_DIR/
        sed -e "s:^filters_path=.*$:filters_path=$CINDER_CONF_DIR/rootwrap.d:" -i $CINDER_CONF_DIR/rootwrap.conf
        chown root:root $CINDER_CONF_DIR/rootwrap.conf
        chmod 0644 $CINDER_CONF_DIR/rootwrap.conf
    fi
    ### end
    EOH
    environment({
      'CINDER_DIR' => cinder_path,
      'CINDER_CONF_DIR' => '/etc/cinder'
    })
    not_if {File.exists?("/etc/cinder/rootwrap.d")}
  end
else
  unless %w(redhat centos suse).include? node.platform
    package "cinder-common"
    package "python-mysqldb"
    package "python-cinder"
  else
    package "openstack-cinder"
  end
end

db_settings = fetch_database_settings
glance_settings = CrowbarConfig.fetch("openstack", "glance")
nova_settings = CrowbarConfig.fetch("openstack", "nova")

include_recipe "database::client"
include_recipe "#{db_settings[:backend_name]}::client"
include_recipe "#{db_settings[:backend_name]}::python-client"

sql_connection = "#{db_settings[:url_scheme]}://#{node[:cinder][:db][:user]}:#{node[:cinder][:db][:password]}@#{db_settings[:address]}/#{node[:cinder][:db][:database]}"

my_ipaddress = Chef::Recipe::Barclamp::Inventory.get_network_by_type(node, "admin").address
node[:cinder][:api][:bind_host] = my_ipaddress

node[:cinder][:my_ip] = my_ipaddress

if node[:cinder][:api][:protocol] == 'https'
  if node[:cinder][:ssl][:generate_certs]
    package "openssl"
    ruby_block "generate_certs for cinder" do
      block do
        unless ::File.exists? node[:cinder][:ssl][:certfile] and ::File.exists? node[:cinder][:ssl][:keyfile]
          require "fileutils"

          Chef::Log.info("Generating SSL certificate for cinder...")

          [:certfile, :keyfile].each do |k|
            dir = File.dirname(node[:cinder][:ssl][k])
            FileUtils.mkdir_p(dir) unless File.exists?(dir)
          end

          # Generate private key
          %x(openssl genrsa -out #{node[:cinder][:ssl][:keyfile]} 4096)
          if $?.exitstatus != 0
            message = "SSL private key generation failed"
            Chef::Log.fatal(message)
            raise message
          end
          FileUtils.chown "root", node[:cinder][:group], node[:cinder][:ssl][:keyfile]
          FileUtils.chmod 0640, node[:cinder][:ssl][:keyfile]

          # Generate certificate signing requests (CSR)
          conf_dir = File.dirname node[:cinder][:ssl][:certfile]
          ssl_csr_file = "#{conf_dir}/signing_key.csr"
          ssl_subject = "\"/C=US/ST=Unset/L=Unset/O=Unset/CN=#{node[:fqdn]}\""
          %x(openssl req -new -key #{node[:cinder][:ssl][:keyfile]} -out #{ssl_csr_file} -subj #{ssl_subject})
          if $?.exitstatus != 0
            message = "SSL certificate signed requests generation failed"
            Chef::Log.fatal(message)
            raise message
          end

          # Generate self-signed certificate with above CSR
          %x(openssl x509 -req -days 3650 -in #{ssl_csr_file} -signkey #{node[:cinder][:ssl][:keyfile]} -out #{node[:cinder][:ssl][:certfile]})
          if $?.exitstatus != 0
            message = "SSL self-signed certificate generation failed"
            Chef::Log.fatal(message)
            raise message
          end

          File.delete ssl_csr_file  # Nobody should even try to use this
        end # unless files exist
      end # block
    end # ruby_block
  else # if generate_certs
    unless ::File.exists? node[:cinder][:ssl][:certfile]
      message = "Certificate \"#{node[:cinder][:ssl][:certfile]}\" is not present."
      Chef::Log.fatal(message)
      raise message
    end
    # we do not check for existence of keyfile, as the private key is allowed
    # to be in the certfile
  end # if generate_certs

  if node[:cinder][:ssl][:cert_required] and !::File.exists? node[:cinder][:ssl][:ca_certs]
    message = "Certificate CA \"#{node[:cinder][:ssl][:ca_certs]}\" is not present."
    Chef::Log.fatal(message)
    raise message
  end
end

availability_zone = nil
unless node[:crowbar_wall].nil? or node[:crowbar_wall][:openstack].nil?
  if node[:crowbar_wall][:openstack][:availability_zone] != ""
    availability_zone = node[:crowbar_wall][:openstack][:availability_zone]
  end
end

if node[:cinder][:ha][:enabled]
  admin_address = Chef::Recipe::Barclamp::Inventory.get_network_by_type(node, "admin").address
  bind_host = admin_address
  bind_port = node[:cinder][:ha][:ports][:api]
else
  bind_host = node[:cinder][:api][:bind_open_address] ? "0.0.0.0" : node[:cinder][:api][:bind_host]
  bind_port = node[:cinder][:api][:bind_port]
end

template "/etc/cinder/cinder.conf" do
  source "cinder.conf.erb"
  owner "root"
  group node[:cinder][:group]
  mode 0640
  variables(
    :bind_host => bind_host,
    :bind_port => bind_port,
    :use_multi_backend => node[:cinder][:use_multi_backend],
    :volumes => node[:cinder][:volumes],
    :sql_connection => sql_connection,
    :rabbit_settings => fetch_rabbitmq_settings,
    :glance_server_protocol => glance_settings.fetch("protocol", "http"),
    :glance_server_host => glance_settings.fetch("host", "127.0.0.1"),
    :glance_server_port => glance_settings.fetch("port", 9292),
    :glance_server_insecure => glance_settings.fetch("insecure", false),
    :nova_api_insecure => nova_settings.fetch("insecure", false),
    :availability_zone => availability_zone,
    :keystone_settings => KeystoneHelper.keystone_settings(node, :cinder),
    :strict_ssh_host_key_policy => node[:cinder][:strict_ssh_host_key_policy],
    :default_availability_zone => node[:cinder][:default_availability_zone]
    )
end

node.save
