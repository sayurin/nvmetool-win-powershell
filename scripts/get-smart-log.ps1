<#
get-smart-log.ps1: Sample script for getting SMART Log data from an NVMe drive using Windows' inbox device driver

Usage: ./get-smart-log.ps1 <PhysicalDriveNo>

Copyright (c) 2021 Kenichiro Yoshii
Copyright (c) 2021 Hagiwara Solutions Co., Ltd.
#>
Param([parameter(mandatory)][Int]$PhyDrvNo)

$KernelService = Add-Type -Name 'Kernel32' -Namespace 'Win32' -PassThru -MemberDefinition @"
    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    public static extern IntPtr CreateFile(
        String lpFileName,
        UInt32 dwDesiredAccess,
        UInt32 dwShareMode,
        IntPtr lpSecurityAttributes,
        UInt32 dwCreationDisposition,
        UInt32 dwFlagsAndAttributes,
        IntPtr hTemplateFile);

    [DllImport("Kernel32.dll", SetLastError = true)]
    public static extern bool DeviceIoControl(
        IntPtr  hDevice,
        int     oControlCode,
        IntPtr  InBuffer,
        int     nInBufferSize,
        IntPtr  OutBuffer,
        int     nOutBufferSize,
        ref int pBytesReturned,
        IntPtr  Overlapped);

    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool CloseHandle(IntPtr hObject);
"@

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

[StructLayout(LayoutKind.Sequential, Pack = 1)]
public struct NVMeStorageQueryProperty {
    public UInt32 PropertyId;
    public UInt32 QueryType;
    public UInt32 ProtocolType;
    public UInt32 DataType;
    public UInt32 ProtocolDataRequestValue;
    public UInt32 ProtocolDataRequestSubValue;
    public UInt32 ProtocolDataOffset;
    public UInt32 ProtocolDataLength;
    public UInt32 FixedProtocolReturnData;
    public UInt32 ProtocolDataRequestSubValue2;
    public UInt32 ProtocolDataRequestSubValue3;
    public UInt32 Reserved0;
    public SMARTData SMARTData;
}

[StructLayout(LayoutKind.Explicit, Size = 512)]
public struct SMARTData {
    // Followings are the data structure of SMART Log page in NVMe rev1.4b
    [FieldOffset(  0)] public Byte    CriticalWarning;
    [FieldOffset(  1)] public UInt16  Temperature;
    [FieldOffset(  3)] public Byte    AvailableSpare;
    [FieldOffset(  4)] public Byte    AvailableSpareThreshold;
    [FieldOffset(  5)] public Byte    PercentageUsed;
    [FieldOffset(  6)] public Byte    EnduranceGroupSummary;
    [FieldOffset( 32)] public UInt128 DataUnitRead;
    [FieldOffset( 48)] public UInt128 DataUnitWritten;
    [FieldOffset( 64)] public UInt128 HostReadCommands;
    [FieldOffset( 80)] public UInt128 HostWriteCommands;
    [FieldOffset( 96)] public UInt128 ControllerBusyTime;
    [FieldOffset(112)] public UInt128 PowerCycle;
    [FieldOffset(128)] public UInt128 PowerOnHours;
    [FieldOffset(144)] public UInt128 UnsafeShutdowns;
    [FieldOffset(160)] public UInt128 MediaErrors;
    [FieldOffset(176)] public UInt128 ErrorLogInfoEntryNum;
    [FieldOffset(192)] public UInt32  WCTempTime;
    [FieldOffset(196)] public UInt32  CCTempTime;
    [FieldOffset(200)] public UInt16  TempSensor1;
    [FieldOffset(202)] public UInt16  TempSensor2;
    [FieldOffset(204)] public UInt16  TempSensor3;
    [FieldOffset(206)] public UInt16  TempSensor4;
    [FieldOffset(208)] public UInt16  TempSensor5;
    [FieldOffset(210)] public UInt16  TempSensor6;
    [FieldOffset(212)] public UInt16  TempSensor7;
    [FieldOffset(214)] public UInt16  TempSensor8;
    [FieldOffset(216)] public UInt32  TMT1TransitionCount;
    [FieldOffset(220)] public UInt32  TMT2TransitionCount;
    [FieldOffset(224)] public UInt32  TMT1TotalTime;
    [FieldOffset(228)] public UInt32  TMT2TotalTime;
}

[StructLayout(LayoutKind.Sequential)]
public struct UInt128 {
    public UInt64 Low;
    public UInt64 High;
    public override String ToString() {
        return String.Format("0x{0:X8}{1:X8}", High, Low);
    }
}
"@

$AccessMask = "3221225472"; # = 0xC00000000 = GENERIC_READ (0x80000000) | GENERIC_WRITE (0x40000000)
$AccessMode = 3; # FILE_SHARE_READ | FILE_SHARE_WRITE
$AccessEx   = 3; # OPEN_EXISTING
$AccessAttr = 0x40; # FILE_ATTRIBUTE_DEVICE

$DeviceHandle = $KernelService::CreateFile("\\.\PhysicalDrive$PhyDrvNo", [System.Convert]::ToUInt32($AccessMask), $AccessMode, [System.IntPtr]::Zero, $AccessEx, $AccessAttr, [System.IntPtr]::Zero);

$LastError = [ComponentModel.Win32Exception][Runtime.InteropServices.Marshal]::GetLastWin32Error()
if ($DeviceHandle -eq [System.IntPtr]::Zero) {
     Write-Output "`n[E] CreateFile failed: $LastError";
     Return;
}

# offsetof(STORAGE_PROPERTY_QUERY, AdditionalParameters)
#  + sizeof(STORAGE_PROTOCOL_SPECIFIC_DATA)
#  + sizeof(NVME_SMART_INFO_LOG) = 560
$OutBufferSize = 8 + 40 + 512; # = 560
$OutBuffer     = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($OutBufferSize);

$Property      = New-Object NVMeStorageQueryProperty;
$PropertySize  = [System.Runtime.InteropServices.Marshal]::SizeOf($Property);

if ( $PropertySize -ne $OutBufferSize ) {
    Write-Output "`n[E] Size of structure is $PropertySize bytes, expect 560 bytes, stop";
    Return;
}

$Property.PropertyId    = 50; # StorageDeviceProtocolSpecificProperty
$Property.QueryType     = 0;  # PropertyStandardQuery
$Property.ProtocolType  = 3;  # ProtocolTypeNvme
$Property.DataType      = 2;  # NVMeDataTypeLogPage

$Property.ProtocolDataRequestValue      = 2; # NVME_LOG_PAGE_HEALTH_INFO
$Property.ProtocolDataRequestSubValue   = [System.Convert]::ToUInt32("4294967295"); # Namespace ID (0xFFFFFFFF)

$Property.ProtocolDataOffset = 40;  # sizeof(STORAGE_PROTOCOL_SPECIFIC_DATA)
$Property.ProtocolDataLength = 512; # sizeof(NVME_SMART_INFO_LOG)

$ByteRet = 0;
$IoControlCode = 0x2d1400; # IOCTL_STORAGE_QUERY_PROPERTY

[System.Runtime.InteropServices.Marshal]::StructureToPtr($Property, $OutBuffer, [System.Boolean]::false);
$CallResult = $KernelService::DeviceIoControl($DeviceHandle, $IoControlCode, $OutBuffer, $OutBufferSize, $OutBuffer, $OutBufferSize, [ref]$ByteRet, [System.IntPtr]::Zero);

$LastError = [ComponentModel.Win32Exception][Runtime.InteropServices.Marshal]::GetLastWin32Error();
if ( $CallResult -eq 0 ) {
    Write-Output "`n[E] DeviceIoControl() failed: $LastError";
    Return;
}

if ( $ByteRet -ne 560 ) {
    Write-Output "`n[E] Data size returned ($ByteRet bytes) is wrong; expect $OutBufferSize bytes";
    Return;
}

$SMARTData = [SMARTData][System.Runtime.InteropServices.Marshal]::PtrToStructure([IntPtr]::Add($OutBuffer, 48), [Type][SMARTData]);
Write-Output @"
Critical Warning: $('0x{0:X2}' -f $SMARTData.CriticalWarning)
Composite Temperature: $($SMARTData.Temperature) (K)
Available Spare: $($SMARTData.AvailableSpare) (%)
Available Spare Threshold: $($SMARTData.AvailableSpareThreshold) (%)
Percentage Used: $($SMARTData.PercentageUsed) (%)
Endurance Group Summary: $('0x{0:X2}' -f $SMARTData.EnduranceGroupSummary)
Data Unit Read: $($SMARTData.DataUnitRead)
Data Unit Written: $($SMARTData.DataUnitWritten)
Host Read Commands: $($SMARTData.HostReadCommands)
Host Write Commands: $($SMARTData.HostWriteCommands)
Controller Busy Time: $($SMARTData.ControllerBusyTime) (minutes)
Power Cycles: $($SMARTData.PowerCycle)
Power On Hours: $($SMARTData.PowerOnHours) (hours)
Unsafe Shutdowns: $($SMARTData.UnsafeShutdowns)
Media and Data Integrity Errors: $($SMARTData.MediaErrors)
Number of Error Information Entries: $($SMARTData.ErrorLogInfoEntryNum)
Warning Composite Temperature Time: $($SMARTData.WCTempTime) (minutes)
Critical Composite Temperature Time: $($SMARTData.CCTempTime) (minutes)
Temperature Sensor 1: $($SMARTData.TempSensor1) (K)
Temperature Sensor 2: $($SMARTData.TempSensor2) (K)
Temperature Sensor 3: $($SMARTData.TempSensor3) (K)
Temperature Sensor 4: $($SMARTData.TempSensor4) (K)
Temperature Sensor 5: $($SMARTData.TempSensor5) (K)
Temperature Sensor 6: $($SMARTData.TempSensor6) (K)
Temperature Sensor 7: $($SMARTData.TempSensor7) (K)
Temperature Sensor 8: $($SMARTData.TempSensor8) (K)
Thermal Management Temperature 1 Transition Count: $($SMARTData.TMT1TransitionCount) (times)
Thermal Management Temperature 2 Transition Count: $($SMARTData.TMT2TransitionCount) (times)
Total Time For Thermal Management Temperature 1: $($SMARTData.TMT1TotalTime) (seconds)
Total Time For Thermal Management Temperature 2: $($SMARTData.TMT2TotalTime) (seconds)
"@

[System.Runtime.InteropServices.Marshal]::FreeHGlobal($OutBuffer);
[void]$KernelService::CloseHandle($DeviceHandle);
