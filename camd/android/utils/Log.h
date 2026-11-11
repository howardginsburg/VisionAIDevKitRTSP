// Stand-in for Android's <utils/Log.h>, which inline code in the qmmf headers includes; logging from
// those headers is compiled out.
#pragma once

#ifndef ALOGE
#define ALOGE(...) ((void)0)
#define ALOGW(...) ((void)0)
#define ALOGI(...) ((void)0)
#define ALOGD(...) ((void)0)
#define ALOGV(...) ((void)0)
#endif
