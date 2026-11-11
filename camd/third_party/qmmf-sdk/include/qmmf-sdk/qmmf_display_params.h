/*
* Copyright (c) 2016, 2018, The Linux Foundation. All rights reserved.
*
* Redistribution and use in source and binary forms, with or without
* modification, are permitted provided that the following conditions are
* met:
*     * Redistributions of source code must retain the above copyright
*       notice, this list of conditions and the following disclaimer.
*     * Redistributions in binary form must reproduce the above
*       copyright notice, this list of conditions and the following
*       disclaimer in the documentation and/or other materials provided
*       with the distribution.
*     * Neither the name of The Linux Foundation nor the names of its
*       contributors may be used to endorse or promote products derived
*       from this software without specific prior written permission.
*
* THIS SOFTWARE IS PROVIDED "AS IS" AND ANY EXPRESS OR IMPLIED
* WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
* MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NON-INFRINGEMENT
* ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS
* BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
* CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
* SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR
* BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
* WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE
* OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN
* IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*/

/*! @file qmmf_display_params.h
*/

#pragma once


#include <sys/types.h>
#include <cstdint>
#include <functional>
#include <vector>

namespace qmmf {
namespace display {

typedef int32_t status_t;


/**
 *  This enum represents display device types where contents can be rendered.
 */
enum class DisplayType {
  kPrimary,     /**< Main physical display which is */
                /**< attached to the handheld device. */
  kHDMI,        /**< HDMI physical display which is generally detachable. */
  kVirtual,     /**< Contents would be rendered into the output buffer */
                /**< provided by the client e.g. wireless display. */
  kDisplayMax,
};

/**
 *  This enum represents states of a display device.
 */
enum class DisplayState {
  kStateOff,         /**< Display is OFF. Contents are not rendered in this */
   /**< state. Client will not receive VSync events in this state. */
   /**< This is default state as well. */
  kStateOn,         /**< Display is ON. Contents are rendered in this state. */
  kStateDoze,       /**< Display is ON and it is */
  /**< configured in a low power state. */
  kStateDozeSuspend, /**< Display is ON in a low power state and continue */
  /**< showing its current contents indefinitely until the mode changes. */
  kStateStandby,     /**< Display is OFF. Client will continue to receive */
  /**< VSync events in this state if VSync is enabled. Contents are */
  /**< not rendered in this state. */
};

enum class DisplayEventType {
    kError,
    kVsync
};

enum class DisplayErrorType {
  kVSyncError
};

// Display cb will be used to return Vsync and error
typedef struct DisplayCb {
    std::function<void( DisplayEventType event_type,
                        void *event_data,
                        size_t event_data_size)> EventCb;
    std::function<void(int64_t time_stamp)> VSyncCb;
} DisplayCb;

// Session specific callbacks

// Session cb will be mostly used to return state changes - to indicate
// start, stop, pause state transition completions
typedef struct DisplaySessionCb {
  DisplayCb event_cb;
} DisplaySessionCb;

/**
 *  This enum represents different buffer formats supported by display manager.
 */
enum class SurfaceFormat {
  /* All RGB formats, Any new format will be added
   * towards end of this group to maintain backward
   * compatibility.
   */
  kFormatARGB8888,         /**< 8-bits Alpha, Red, Green, Blue */
                           /**< interleaved in ARGB order. */
  kFormatRGBA8888,         /**< 8-bits Red, Green, Blue, Alpha */
                           /**< interleaved in RGBA order. */
  kFormatBGRA8888,         /**< 8-bits Blue, Green, Red, Alpha */
                           /**< interleaved in BGRA order. */
  kFormatXRGB8888,         /**< 8-bits Padding, Red, Green, Blue */
                           /**< interleaved in XRGB order. No Alpha. */
  kFormatRGBX8888,         /**< 8-bits Red, Green, Blue, Padding */
                           /**< interleaved in RGBX order. No Alpha. */
  kFormatBGRX8888,         /**< 8-bits Blue, Green, Red, Padding */
                           /**< interleaved in BGRX order. No Alpha. */
  kFormatRGBA5551,         /**< 5-bits Red, Green, Blue, and 1 */
                           /**< bit Alpha interleaved in RGBA order. */
  kFormatRGBA4444,         /**< 4-bits Red, Green, Blue, Alpha */
                           /**< interleaved in RGBA order. */
  kFormatRGB888,           /**< 8-bits Red, Green, Blue interleaved */
                           /**< in RGB order. No Alpha. */
  kFormatBGR888,           /**< 8-bits Blue, Green, Red interleaved */
                           /**< in BGR order. No Alpha. */
  kFormatRGB565,           /**< 5-bit Red, 6-bit Green, 5-bit Blue */
                           /**< interleaved in RGB order. No Alpha. */
  kFormatBGR565,           /**< 5-bit Blue, 6-bit Green, 5-bit Red */
                           /**< interleaved in BGR order. No Alpha. */
  kFormatRGBA8888Ubwc,     /**< UBWC aligned RGBA8888 format */
  kFormatRGBX8888Ubwc,     /**< UBWC aligned RGBX8888 format */
  kFormatBGR565Ubwc,       /**< UBWC aligned BGR565 format */
  kFormatRGBA1010102,      /**< 10-bits Red, Green, Blue, Alpha */
                           /**< interleaved in RGBA order. */
  kFormatARGB2101010,      /**< 10-bits Alpha, Red, Green, Blue */
                           /**< interleaved in ARGB order. */
  kFormatRGBX1010102,      /**< 10-bits Red, Green, Blue, Padding */
                           /**< interleaved in RGBX order. No Alpha. */
  kFormatXRGB2101010,      /**< 10-bits Padding, Red, Green, Blue */
                           /**< interleaved in XRGB order. No Alpha. */
  kFormatBGRA1010102,      /**< 10-bits Blue, Green, Red, Alpha */
                           /**< interleaved in BGRA order. */
  kFormatABGR2101010,      /**< 10-bits Alpha, Blue, Green, Red */
                           /**< interleaved in ABGR order. */
  kFormatBGRX1010102,      /**< 10-bits Blue, Green, Red, Padding */
                           /**< interleaved in BGRX order. No Alpha. */
  kFormatXBGR2101010,      /**< 10-bits Padding, Blue, Green, Red */
                           /**< interleaved in XBGR order. No Alpha. */
  kFormatRGBA1010102Ubwc,  /**< UBWC aligned RGBA1010102 format */
  kFormatRGBX1010102Ubwc,  /**< UBWC aligned RGBX1010102 format */

  /* All YUV-Planar formats, Any new format will be added
   * towards end of this group to maintain
   * backward compatibility.
   */
  kFormatYCbCr420Planar = 0x100,  /**< Y-plane: y(0), y(1), y(2) ... y(n) \n */
    /**< 2x2 subsampled U-plane: u(0), u(2) ... u(n-1) \n */
    /**< 2x2 subsampled V-plane: v(0), v(2) ... v(n-1) */

  kFormatYCrCb420Planar,          /**< Y-plane: y(0), y(1), y(2) ... y(n) \n */
    /**< 2x2 subsampled V-plane: v(0), v(2) ... v(n-1) \n */
    /**< 2x2 subsampled U-plane: u(0), u(2) ... u(n-1) */

  kFormatYCrCb420PlanarStride16,  /**< kFormatYCrCb420Planar with */
    /**< stride aligned to 16 bytes */

  /* All YUV-Semiplanar formats, Any new format
   * will be added towards end of this group to
   * maintain backward compatibility.
   */
  kFormatYCbCr420SemiPlanar = 0x200,
                         /**< Y-plane: y(0), y(1), y(2) ... y(n) \n         */
                         /**< 2x2 subsampled interleaved UV-plane: \n       */
                         /**<  u(0), v(0), u(2), v(2) ... u(n-1), v(n-1) \n */
                         /**< aka NV12.                                     */

  kFormatYCrCb420SemiPlanar,
                         /**< Y-plane: y(0), y(1), y(2) ... y(n) \n          */
                         /**< 2x2 subsampled interleaved VU-plane: \n        */
                         /**<  v(0), u(0), v(2), u(2) ... v(n-1), u(n-1) \n  */
                         /**< aka NV21.                                      */

  kFormatYCbCr420SemiPlanarVenus,
                            /**< Y-plane: y(0), y(1), y(2) ... y(n) \n   */
                            /**< 2x2 subsampled interleaved UV-plane: \n  */
                            /**< u(0), v(0), u(2), v(2) ... u(n-1), v(n-1)*/

  kFormatYCbCr422H1V2SemiPlanar,
                         /**< Y-plane: y(0), y(1), y(2) ... y(n) \n     */
                         /**< vertically subsampled interleaved UV-plane: \n */
                         /**<    u(0), v(1), u(2), v(3) ... u(n-1), v(n)     */

  kFormatYCrCb422H1V2SemiPlanar, /**< Y-plane: y(0), y(1), y(2) ... y(n) \n */
                        /**< vertically subsampled interleaved VU-plane: \n */
                        /**<    v(0), u(1), v(2), u(3) ... v(n-1), u(n)     */

  kFormatYCbCr422H2V1SemiPlanar,
                     /**< Y-plane: y(0), y(1), y(2) ... y(n) \n     */
                     /**< horizontally subsampled interleaved UV-plane: \n  */
                     /**<    u(0), v(1), u(2), v(3) ... u(n-1), v(n)        */

  kFormatYCrCb422H2V1SemiPlanar,
                     /**< Y-plane: y(0), y(1), y(2) ... y(n) \n   */
                     /**< horizontally subsampled interleaved VU-plane: \n */
                     /**<    v(0), u(1), v(2), u(3) ... v(n-1), u(n)       */

  kFormatYCbCr420SPVenusUbwc,
                      /**< UBWC aligned YCbCr420SemiPlanarVenus format  */

  kFormatYCrCb420SemiPlanarVenus,
                         /**< Y-plane: y(0), y(1), y(2) ... y(n) \n  */
                         /**< 2x2 subsampled interleaved UV-plane: \n      */
                         /**<    v(0), u(0), v(2), u(2) ... v(n-1), u(n-1) */

  kFormatYCbCr420P010,
                /**< 16 bit Y-plane with 5 MSB bits set to 0: \n        */
                /**< y(0), y(1), y(2) ... y(n) \n                       */
                /**< 2x2 subsampled interleaved 10 bit UV-plane with \n */
                /**< 5 MSB bits set to 0: \n                            */
                /**<    u(0), v(0), u(2), v(2) ... u(n-1), v(n-1) \n    */
                /**< aka P010.                                          */

  kFormatYCbCr420TP10Ubwc,  /**< UBWC aligned YCbCr420TP10 format.    */

/* All YUV-Packed formats, Any new format
 * will be added towards end of this group to maintain
 * backward compatibility.
 */
  kFormatYCbCr422H2V1Packed = 0x300,
   /**< Y-plane interleaved with horizontally subsampled U/V by \n  */
   /**< factor of 2 \n                                              */
   /**<    y(0), u(0), y(1), v(0), y(2), u(2), y(3), v(2) \n        */
   /**<    y(n-1), u(n-1), y(n), v(n-1)                             */

  kFormatInvalid = (int32_t)0xFFFFFFFF, /**< (int32_t)0xFFFFFFFF */
};

/**
 * This structure defines rotation and flip values for a display layer.
 *
 */
typedef struct SurfaceTransform {
  float rotation;        /**< rotate the layer based on left */
                         /**< most pixel coordinate. */
  bool flip_horizontal;  /**< Mirror reversal of the layer */
                         /**< across a horizontal axis. */
  bool flip_vertical;    /**< Mirror reversal of the layer */
                         /**<across a vertical axis. */
} SurfaceTransform;

/**
 * Input configuration params set by the client for buffer allocation.
 *
 */
typedef struct SurfaceConfig {
  uint32_t width;
  uint32_t height;
  SurfaceFormat format;
  uint32_t buffer_count; /**< Number of buffers to be allocated/used. */
  bool cache; /**< To allocate cached or uncached gralloc buffers. */
  bool use_buffer; /**< The client will allocate the */
                   /**<buffers or display adapter shall use it. */
  SurfaceTransform surface_transform;
  uint32_t z_order;
} SurfaceConfig;

/**
 * Holds the information about the allocated buffer.
 */
typedef struct PlaneInfo {
  void *buf;
  int32_t ion_fd;
  uint32_t width;
  uint32_t height;
  uint32_t stride;
  uint32_t size;
  uint32_t offset;
} PlaneInfo;

/**
 * Holds the information about the
 * input/output configuration of an output buffer.
 */
typedef struct SurfaceBuffer {
  int32_t buf_id;
  PlaneInfo plane_info[4];
  SurfaceFormat format;
  int32_t acquire_fence;
  int32_t release_fence;
  size_t   capacity;
} SurfaceBuffer;

/**
 * This structure defines a rectanglular area inside a display layer.
 */
typedef struct SurfaceRect {
  float left;
  float top;
  float right;
  float bottom;
} SurfaceRect;

/**
 * This enum represents display layer blending types.
 *
 */
enum class SurfaceBlending {
  kBlendingPremultiplied, /**< Pixel color is expressed using premultiplied */
                          /**< alpha in RGBA tuples. If plane alpha is less */
                          /**< than 0xFF, apply modulation as well. */
                          /**< pixel.rgb = src.rgb + dest.rgb x (1 - src.a) */

  kBlendingOpaque,  /**< Pixel color is expressed using straight alpha */
                    /**< in color tuples. It is constant blend */
                    /**< operation. The layer would appear opaque if */
                    /**< plane alpha is 0xFF. */


  kBlendingCoverage, /**< Pixel color is expressed using straight */
                     /**< alpha in color tuples. If plane alpha is */
                     /**< less than 0xff, apply modulation as well. */
                   /**< pixel.rgb = src.rgb x src.a + dest.rgb x (1 - src.a) */
};

/**
 * This structure defines flags associated with a layer.
 *
 */
typedef union SurfaceFlags {
      uint32_t solid_fill; /**< This flag shall be set by client to */
                           /**< indicate that this layer is for */
                           /**< solid fill without input buffer. */
                           /**< Display Device will use SDE HW feature */
                           /**< to achieve it. */
      uint32_t cursor;     /**< This flag shall be set by client to indicate */
                           /**< that this layer is a cursor. Display Device */
                           /**< may handle this layer using HWCursor */
} SurfaceFlags;

/**
 * Surface runtime params set by client on
 * how to compose this Surface with other Surfaces
 *
 */
typedef struct SurfaceParam {
    SurfaceTransform surface_transform;
    SurfaceRect src_rect;
    /**< Rectangular area of the buffer to consider for composition. */
    SurfaceRect dst_rect;
     /**< The target position where the frame will be displayed. Cropping   */
     /**< rectangle is scaled to fit into this rectangle. The origin is the */
     /**< top-left corner of the screen.                                    */
    SurfaceBlending surface_blending;
    SurfaceFlags surface_flags;
    uint8_t plane_alpha;
    /**< Alpha value applied to the whole surface. Value of each pixel is */
    /**< computed as: \n if(kBlendingPremultiplied) { \n                  */
    /**<                  pixel.RGB = pixel.RGB * planeAlpha/255 \n       */
    /**<               } \n                                               */
    /**<               pixel.a = pixel.a * planeAlpha                     */
    uint32_t frame_rate;
    /**< Rate at which frames are being updated for this layer. */
    uint32_t solid_fill_color;
    /**< Solid color used to fill the layer when no content is associated */
    /**< with the layer. */
} SurfaceParam;

/**
 * This structure defines configuration for
 * variable properties of a display device.
 *
 */
typedef struct DisplayConfig {
  uint32_t x_pixels;
  /**< Total number of pixels in X-direction on the display panel. */
  uint32_t y_pixels;
  /**< Total number of pixels in Y-direction on the display panel. */
  float x_dpi;
  /**< Dots per inch in X-direction. */
  float y_dpi;
  /**< Dots per inch in Y-direction. */
  uint32_t fps;
  /**< Frame rate per second. */
  uint32_t vsync_period_ns;
  /**< VSync period in nanoseconds. */
  bool is_yuv;
  /**< If the display output is in YUV format. */
  bool underscan;
  /**< If display support CE underscan */
} DisplayConfig;

/**
 *  Display specific parameters
 *
 */
enum class DisplayParamType {
  kSaturation,
  kContrast,
  kBrightness,
  kDisplayState
};

/*! @brief This enum represents the events received by Display HAL. */
enum DisplayEvent {
  kIdleTimeout,        // Event triggered by Idle Timer.
  kThermalEvent,       // Event triggered by Thermal.
  kIdlePowerCollapse,  // Event triggered by Idle Power Collapse.
  kPanelDeadEvent,     // Event triggered by ESD.
};

};
}; // namespace qmmf::display
