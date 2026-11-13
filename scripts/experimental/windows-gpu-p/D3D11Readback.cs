using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace ClaudeGpuProbe
{
    public static class D3D11Readback
    {
        [StructLayout(LayoutKind.Sequential)] public struct TextureDesc
        {
            public uint Width, Height, MipLevels, ArraySize, Format;
            public uint SampleCount, SampleQuality, Usage, BindFlags, CpuAccessFlags, MiscFlags;
        }
        [StructLayout(LayoutKind.Sequential)] public struct MappedResource
        { public IntPtr Data; public uint RowPitch, DepthPitch; }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] public struct AdapterDesc1
        {
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Description;
            public uint VendorId, DeviceId, SubSysId, Revision;
            public UIntPtr DedicatedVideoMemory, DedicatedSystemMemory, SharedSystemMemory;
            public uint LuidLow; public int LuidHigh; public uint Flags;
        }

        [DllImport("d3d11.dll", CallingConvention = CallingConvention.StdCall, ExactSpelling = true)]
        private static extern int D3D11CreateDevice(IntPtr adapter, uint driverType, IntPtr software,
            uint flags, IntPtr featureLevels, uint featureLevelCount, uint sdkVersion,
            out IntPtr device, out uint featureLevel, out IntPtr context);

        [UnmanagedFunctionPointer(CallingConvention.StdCall)] private delegate int QueryInterfaceFn(IntPtr self, ref Guid iid, out IntPtr value);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] private delegate int GetAdapterFn(IntPtr self, out IntPtr value);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] private delegate int GetDesc1Fn(IntPtr self, out AdapterDesc1 value);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] private delegate int CreateTexture2DFn(IntPtr self, ref TextureDesc desc, IntPtr initialData, out IntPtr value);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] private delegate int CreateRenderTargetViewFn(IntPtr self, IntPtr resource, IntPtr desc, out IntPtr value);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] private delegate void ClearRenderTargetViewFn(IntPtr self, IntPtr view, [In, MarshalAs(UnmanagedType.LPArray, SizeConst = 4)] float[] rgba);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] private delegate void CopyResourceFn(IntPtr self, IntPtr destination, IntPtr source);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] private delegate int MapFn(IntPtr self, IntPtr resource, uint subresource, uint mapType, uint flags, out MappedResource mapped);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] private delegate void UnmapFn(IntPtr self, IntPtr resource, uint subresource);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] private delegate int GetDeviceRemovedReasonFn(IntPtr self);

        private static T Method<T>(IntPtr instance, int slot) where T : class
        {
            if (instance == IntPtr.Zero) throw new InvalidOperationException("Null COM interface");
            IntPtr address = Marshal.ReadIntPtr(Marshal.ReadIntPtr(instance), checked(slot * IntPtr.Size));
            return (T)(object)Marshal.GetDelegateForFunctionPointer(address, typeof(T));
        }
        private static string Hex(int value) { return "0x" + unchecked((uint)value).ToString("X8"); }
        private static void Check(int value, string name, IDictionary<string, object> calls)
        {
            calls[name] = Hex(value);
            if (value < 0) throw new COMException(name + " failed: " + Hex(value), value);
        }
        private static void Release(ref IntPtr value)
        {
            if (value != IntPtr.Zero) { Marshal.Release(value); value = IntPtr.Zero; }
        }

        // Safe offline method: native layouts only; no DLL import or COM call.
        public static Dictionary<string, object> Layout()
        {
            var result = new Dictionary<string, object>();
            result["PointerBytes"] = IntPtr.Size;
            result["TextureDescBytes"] = Marshal.SizeOf(typeof(TextureDesc));
            result["MappedResourceBytes"] = Marshal.SizeOf(typeof(MappedResource));
            result["AdapterDesc1Bytes"] = Marshal.SizeOf(typeof(AdapterDesc1));
            result["AdapterVendorOffset"] = Marshal.OffsetOf(typeof(AdapterDesc1), "VendorId").ToInt32();
            result["AdapterMemoryOffset"] = Marshal.OffsetOf(typeof(AdapterDesc1), "DedicatedVideoMemory").ToInt32();
            result["AdapterLuidOffset"] = Marshal.OffsetOf(typeof(AdapterDesc1), "LuidLow").ToInt32();
            result["AdapterFlagsOffset"] = Marshal.OffsetOf(typeof(AdapterDesc1), "Flags").ToInt32();
            return result;
        }

        // GPU entry point. Invoke ONLY in the intended guest, in a timeout-bounded child process.
        public static Dictionary<string, object> Run()
        {
            var result = new Dictionary<string, object>();
            var calls = new Dictionary<string, object>();
            result["Succeeded"] = false;
            result["Calls"] = calls;
            result["DriverType"] = "D3D_DRIVER_TYPE_HARDWARE (1); no fallback";
            result["Format"] = "DXGI_FORMAT_R8G8B8A8_UNORM (28)";
            result["ClearRgbaFloat"] = new float[] { 1.0f, 0.5f, 0.25f, 1.0f };
            result["ExpectedRgba8"] = new int[] { 255, 128, 64, 255 };
            result["AllowedRgba8Min"] = new int[] { 255, 127, 64, 255 };
            result["AllowedRgba8Max"] = new int[] { 255, 128, 64, 255 };
            result["Quantization"] = "Only 0.5*255 tie permits 127 or 128; all other channels exact.";
            result["PixelsRequired"] = 4;
            result["Scope"] = "One 2x2 offscreen ClearRenderTargetView plus copy/readback; not shader, desktop or browser validation.";
            var timer = Stopwatch.StartNew();
            IntPtr device = IntPtr.Zero, context = IntPtr.Zero, dxgi = IntPtr.Zero;
            IntPtr adapter = IntPtr.Zero, adapter1 = IntPtr.Zero, target = IntPtr.Zero;
            IntPtr view = IntPtr.Zero, staging = IntPtr.Zero;
            bool mapped = false;
            try
            {
                if (IntPtr.Size != 8 || Marshal.SizeOf(typeof(TextureDesc)) != 44 ||
                    Marshal.SizeOf(typeof(MappedResource)) != 16 || Marshal.SizeOf(typeof(AdapterDesc1)) != 312)
                    throw new InvalidOperationException("Unexpected native layout; x64 required");
                uint featureLevel;
                // Microsoft requires a null adapter with HARDWARE. Never retry with WARP/REFERENCE/SOFTWARE.
                Check(D3D11CreateDevice(IntPtr.Zero, 1, IntPtr.Zero, 0, IntPtr.Zero, 0, 7,
                    out device, out featureLevel, out context), "D3D11CreateDevice", calls);
                result["FeatureLevelHex"] = "0x" + featureLevel.ToString("X4");
                Guid dxgiIid = new Guid("54ec77fa-1377-44e6-8c32-88fd5f44c84c");
                Check(Method<QueryInterfaceFn>(device, 0)(device, ref dxgiIid, out dxgi), "QueryIDXGIDevice", calls);
                Check(Method<GetAdapterFn>(dxgi, 7)(dxgi, out adapter), "GetActualAdapter", calls);
                Guid adapterIid = new Guid("29038f61-3839-4626-91fd-086879011a05");
                Check(Method<QueryInterfaceFn>(adapter, 0)(adapter, ref adapterIid, out adapter1), "QueryIDXGIAdapter1", calls);
                AdapterDesc1 description;
                Check(Method<GetDesc1Fn>(adapter1, 10)(adapter1, out description), "GetDesc1", calls);
                result["AdapterDescription"] = description.Description;
                result["VendorIdHex"] = "0x" + description.VendorId.ToString("X4");
                result["DeviceIdHex"] = "0x" + description.DeviceId.ToString("X4");
                result["AdapterLuid"] = unchecked((uint)description.LuidHigh).ToString("X8") + ":" + description.LuidLow.ToString("X8");
                result["AdapterFlags"] = description.Flags;
                result["DedicatedVideoMemoryBytes"] = description.DedicatedVideoMemory.ToUInt64();
                string lower = (description.Description ?? "").ToLowerInvariant();
                bool hardware = description.VendorId == 0x10DE && (description.Flags & 2) == 0 &&
                    !lower.Contains("basic") && !lower.Contains("warp") && !lower.Contains("software");
                result["ActualAdapterIsNvidiaHardware"] = hardware;
                if (!hardware) throw new InvalidOperationException("Actual D3D device is not the required NVIDIA hardware adapter");

                var desc = new TextureDesc { Width = 2, Height = 2, MipLevels = 1, ArraySize = 1,
                    Format = 28, SampleCount = 1, SampleQuality = 0, Usage = 0, BindFlags = 0x20,
                    CpuAccessFlags = 0, MiscFlags = 0 };
                Check(Method<CreateTexture2DFn>(device, 5)(device, ref desc, IntPtr.Zero, out target), "CreateRenderTargetTexture", calls);
                Check(Method<CreateRenderTargetViewFn>(device, 9)(device, target, IntPtr.Zero, out view), "CreateRenderTargetView", calls);
                desc.Usage = 3; desc.BindFlags = 0; desc.CpuAccessFlags = 0x20000;
                Check(Method<CreateTexture2DFn>(device, 5)(device, ref desc, IntPtr.Zero, out staging), "CreateStagingTexture", calls);
                Method<ClearRenderTargetViewFn>(context, 50)(context, view, new float[] { 1.0f, 0.5f, 0.25f, 1.0f });
                Method<CopyResourceFn>(context, 47)(context, staging, target);
                MappedResource readback;
                // Blocking Map synchronizes CopyResource; the parent bounds this entire process at 30 seconds.
                Check(Method<MapFn>(context, 14)(context, staging, 0, 1, 0, out readback), "MapRead", calls);
                mapped = true;
                result["RowPitch"] = readback.RowPitch;
                if (readback.Data == IntPtr.Zero || readback.RowPitch < 8 || readback.RowPitch > Int32.MaxValue)
                    throw new InvalidOperationException("Invalid mapped texture pointer or pitch");
                var actual = new int[4][];
                bool pixelsMatch = true;
                for (int y = 0; y < 2; y++)
                    for (int x = 0; x < 2; x++)
                    {
                        int offset = checked(y * (int)readback.RowPitch + x * 4);
                        var pixel = new int[4];
                        for (int c = 0; c < 4; c++) pixel[c] = Marshal.ReadByte(readback.Data, offset + c);
                        actual[y * 2 + x] = pixel;
                        pixelsMatch &= pixel[0] == 255 && (pixel[1] == 127 || pixel[1] == 128) && pixel[2] == 64 && pixel[3] == 255;
                    }
                result["ActualRgba8Pixels"] = actual;
                result["AllPixelsMatch"] = pixelsMatch;
                Method<UnmapFn>(context, 15)(context, staging, 0); mapped = false;
                Check(Method<GetDeviceRemovedReasonFn>(device, 39)(device), "GetDeviceRemovedReason", calls);
                if (!pixelsMatch) throw new InvalidOperationException("Hardware readback pixels did not match the independent expected values");
                result["Succeeded"] = hardware && pixelsMatch;
            }
            catch (Exception error)
            {
                result["ErrorType"] = error.GetType().FullName;
                result["Error"] = error.Message;
                result["ErrorHResult"] = Hex(error.HResult);
            }
            finally
            {
                if (mapped && context != IntPtr.Zero && staging != IntPtr.Zero)
                    Method<UnmapFn>(context, 15)(context, staging, 0);
                Release(ref staging); Release(ref view); Release(ref target);
                Release(ref adapter1); Release(ref adapter); Release(ref dxgi);
                Release(ref context); Release(ref device);
                timer.Stop(); result["ElapsedMilliseconds"] = timer.ElapsedMilliseconds;
            }
            return result;
        }
    }
}
