# Copyright (c) 2011 VMware, Inc.  All Rights Reserved.
# 
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.

opts :reboot do
  summary "Reboot hosts"
  arg :host, nil, :lookup => VIM::HostSystem, :multi => true
  opt :force, "Reboot even if not in maintenance mode", :default => false
  opt :wait, "Wait for the host to be connected again", :type => :boolean
end

def reboot hosts, opts
  tasks hosts, :RebootHost, :force => opts[:force]

  if opts[:wait]
    puts "Waiting for hosts to reboot ..."
    # There is no proper way to wait for a host to reboot, so we
    # implement a heuristic that is close enough:
    # First we wait for a moment to give the host time to actually
    # disconnect. Then we just wait for it to be responding again.
    sleep 3 * 60

    hosts.each do |host|
      # We could use the property collector here to wait for an
      # update instead of polling.
      while !(host.runtime.connectionState == "connected" && host.runtime.powerState == "poweredOn")
        sleep 10
      end
      puts "Host #{host.name} is back up"
    end
  end
end


opts :evacuate do
  summary "vMotion all VMs away from this host (experimental)"
  arg :src, nil, :lookup => VIM::HostSystem
  arg :dst, nil, :lookup => VIM::ComputeResource, :multi => true
  opt :num, "Maximum concurrent vMotions", :default => 4
end

def evacuate src, dsts, opts
  vim = src._connection
  vms = src.vm
  dst_hosts = dsts.map(&:host).flatten
  checks = ['cpu', 'software']

  dst_hosts.reject! { |host| host == src ||
                             host.runtime.connectionState != 'connected' ||
                             host.runtime.inMaintenanceMode }

  candidates = {}
  vms.each do |vm|
    required_datastores = vm.datastore
    result = vim.serviceInstance.QueryVMotionCompatibility(:vm => vm,
                                                           :host => dst_hosts,
                                                           :compatibility => checks)
    result.reject! { |x| x.compatibility != checks ||
                         x.host.datastore & required_datastores != required_datastores }
    candidates[vm] = result.map { |x| x.host }
  end

  if candidates.any? { |vm,hosts| hosts.empty? }
    puts "The following VMs have no compatible vMotion destination:"
    candidates.select { |vm,hosts| hosts.empty? }.each { |vm,hosts| puts " #{vm.name}" }
    return
  end

  tasks = candidates.map do |vm,hosts|
    host = hosts[rand(hosts.size)]
    vm.MigrateVM_Task(:host => host, :priority => :defaultPriority)
  end

  progress tasks
end


opts :enter_maintenance_mode do
  summary "Put hosts into maintenance mode"
  arg :host, nil, :lookup => VIM::HostSystem, :multi => true
  opt :timeout, "Timeout", :default => 0
  opt :evacuate_powered_off_vms, "Evacuate powered off vms", :type => :boolean
  opt :no_wait, "Don't wait for Task to complete", :type => :boolean
end

def enter_maintenance_mode hosts, opts
  if opts[:no_wait]
    hosts.each do |host|
      host.EnterMaintenanceMode_Task(:timeout => opts[:timeout], :evacuatePoweredOffVms => opts[:evacuate_powered_off_vms])
    end
  else
    tasks hosts, :EnterMaintenanceMode, :timeout => opts[:timeout], :evacuatePoweredOffVms => opts[:evacuate_powered_off_vms]
  end
end


opts :exit_maintenance_mode do
  summary "Take hosts out of maintenance mode"
  arg :host, nil, :lookup => VIM::HostSystem, :multi => true
  opt :timeout, "Timeout", :default => 0
end

def exit_maintenance_mode hosts, opts
  tasks hosts, :ExitMaintenanceMode, :timeout => opts[:timeout]
end


opts :disconnect do
  summary "Disconnect a host"
  arg :host, nil, :lookup => VIM::HostSystem, :multi => true
end

def disconnect hosts
  tasks hosts, :DisconnectHost
end


opts :reconnect do
  summary "Reconnect a host"
  arg :host, nil, :lookup => VIM::HostSystem, :multi => true
  opt :username, "Username", :short => 'u', :default => 'root'
  opt :password, "Password", :short => 'p', :default => ''
end

def reconnect hosts, opts
  spec = {
    :force => false,
    :userName => opts[:username],
    :password => opts[:password],
  }
  tasks hosts, :ReconnectHost
end


opts :add_iscsi_target do
  arg :host, nil, :lookup => VIM::HostSystem, :multi => true
  opt :address, "Address of iSCSI server", :short => 'a', :type => :string, :required => true
  opt :iqn, "IQN of iSCSI target", :short => 'i', :type => :string, :required => true
end

def add_iscsi_target hosts, opts
  hosts.each do |host|
    puts "configuring host #{host.name}"
    storage = host.configManager.storageSystem
    storage.UpdateSoftwareInternetScsiEnabled(:enabled => true)
    adapter = storage.storageDeviceInfo.hostBusAdapter.grep(VIM::HostInternetScsiHba)[0]
    storage.AddInternetScsiStaticTargets(
      :iScsiHbaDevice => adapter.device,
      :targets => [ VIM::HostInternetScsiHbaStaticTarget(:address => opts[:address], :iScsiName => opts[:iqn]) ]
    )
    storage.RescanAllHba
  end
end

opts :add_nfs_datastore do
  arg :host, nil, :lookup => VIM::HostSystem, :multi => true
  opt :name, "Datastore name", :short => 'n', :type => :string, :required => true
  opt :address, "Address of NFS server", :short => 'a', :type => :string, :required => true
  opt :path, "Path on NFS server", :short => 'p', :type => :string, :required => true
end

def add_nfs_datastore hosts, opts
  hosts.each do |host|
    datastoreSystem, = host.collect 'configManager.datastoreSystem'
    spec = {
      :accessMode => 'readWrite',
      :localPath => opts[:name],
      :remoteHost => opts[:address],
      :remotePath => opts[:path]
    }
    datastoreSystem.CreateNasDatastore :spec => spec
  end
end
