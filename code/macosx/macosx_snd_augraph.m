/*
===========================================================================
Copyright (C) 1999-2005 Id Software, Inc.

This file is part of Quake III Arena source code.

Quake III Arena source code is free software; you can redistribute it
and/or modify it under the terms of the GNU General Public License as
published by the Free Software Foundation; either version 2 of the License,
or (at your option) any later version.

Quake III Arena source code is distributed in the hope that it will be
useful, but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with Foobar; if not, write to the Free Software
Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA
===========================================================================
*/

// macosx_snd_augraph.m
// all other sound mixing is portable

#include "../client/snd_local.h"
#include "macosx_local.h"
#include <AudioToolbox/AudioToolbox.h>

#define PRINTERR(req,status,failmsg) { if (status != req) { Com_Printf("%s (%i).\n",failmsg,status); }}
#define FAILERR(req,status,failmsg) { if (status != req) { Com_Printf("%s (%i).\n",failmsg,status); return qfalse; }}

#define sizeofbits(x) (((x+7)&~7)>>3) // round bit number to nearest byte (8 bytes) -- can't rely on (x >> 3)
#define DMA_BUFFER_SAMPLES (PAINTBUFFER_SIZE)

typedef struct sndDriver_s {
	AudioDeviceID				device;
	AUGraph						graph;
	AUNode						outputNode;
	AUNode						mixerNode;
	AudioUnit					mixerUnit;
	AudioStreamBasicDescription	format;
	qboolean					initialized;
	unsigned int				chunkCount;
} sndDriver_t;

static sndDriver_t driver = {0};

//==============================================================================

AudioDeviceID CoreAudio_DefaultDevice(void)
{
	AudioDeviceID device = kAudioDeviceUnknown;
	AudioObjectPropertyAddress property = {kAudioHardwarePropertyDefaultOutputDevice,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMaster};
	UInt32 size = 0;

	PRINTERR(0,AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &property, 0, NULL, &size), "FAILED: could not obtain kAudioHardwarePropertyDefaultOutputDevice size");
	PRINTERR(0,AudioObjectGetPropertyData(kAudioObjectSystemObject, &property, 0, NULL, &size, &device), "FAILED: could not obtain default audio output device");

	return device;
}

AudioStreamBasicDescription CoreAudio_DeviceFormat(AudioDeviceID inDevice)
{
	AudioStreamBasicDescription format = {0};
	AudioObjectPropertyAddress property = { kAudioDevicePropertyStreamFormat, kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMaster };
	UInt32 size = 0;

	PRINTERR(0,AudioObjectGetPropertyDataSize(inDevice, &property, 0, NULL, &size), "FAILED: could not obtain AudioObjectPropertyAddress size");
	PRINTERR(0,AudioObjectGetPropertyData(inDevice, &property, 0, NULL, &size, &format), "FAILED: could not obtain kAudioDevicePropertyStreamFormat");

	return format;
}

/*
===============
SNDDMA_IOProc
===============
*/
OSStatus SNDDMA_IOProc(void *						inRefCon,
					   AudioUnitRenderActionFlags *	ioActionFlags,
					   const AudioTimeStamp *		inTimeStamp,
					   UInt32						inBusNumber,
					   UInt32						inNumberFrames,
					   AudioBufferList *			ioData)
{
	static const float scale = (1.0 / SHRT_MAX);
	short *outInt16 = (short*)ioData->mBuffers[0].mData;
	float *outFloat32 = (float*)ioData->mBuffers[0].mData;
	short *inInt16 = NULL;
	unsigned int i = 0;

	if ( !driver.initialized ) {
		dma.samples = DMA_BUFFER_SAMPLES;
		dma.submission_chunk = inNumberFrames * ioData->mBuffers[0].mNumberChannels;
		driver.initialized = true;
	}

	inInt16 = (short*)dma.buffer + (SNDDMA_GetDMAPos() % dma.samples);

	switch (driver.format.mBitsPerChannel) {
		case 16: for (i=0; i<dma.submission_chunk; i++) { outInt16[i] = inInt16[i]; } break;
		case 32: for (i=0; i<dma.submission_chunk; i++) { outFloat32[i] = inInt16[i] * scale; } break;
		default: break;
	}

	driver.chunkCount++;

    return kAudioHardwareNoError;
}

/*
===============
SNDDMA_InitAUGraph
===============
*/
qboolean SNDDMA_InitAUGraph( void )
{
	AudioComponentDescription outputDescription = {
		kAudioUnitType_Output,
		kAudioUnitSubType_DefaultOutput, // iOS is RemoteIO
		kAudioUnitManufacturer_Apple,
		0,
		0
	};

	AudioComponentDescription mixerDescription = {
		kAudioUnitType_FormatConverter,
		kAudioUnitSubType_AUConverter,
		kAudioUnitManufacturer_Apple,
		0,
		0
	};

	AURenderCallbackStruct callback = {	(AURenderCallback)SNDDMA_IOProc, (void*)&driver };

	Com_Printf( "Initializing AUGraph\n");

	// device & format
	driver.device = CoreAudio_DefaultDevice();

	// ensure the audio device is valid
	if (driver.device == kAudioDeviceUnknown) {
		Com_Printf("audio output device unknown.\n");
		return qfalse;
	}

	driver.format = CoreAudio_DeviceFormat(driver.device);
	driver.format.mFormatID = kAudioFormatLinearPCM;
#if 1 // 32-bit float
	driver.format.mFormatFlags = kAudioFormatFlagsNativeFloatPacked;
	driver.format.mBitsPerChannel = 32;
#else // 16-bit integer
	driver.format.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
	driver.format.mBitsPerChannel = 16;
#endif
	driver.format.mChannelsPerFrame = 2;
	driver.format.mBytesPerFrame = sizeofbits(driver.format.mBitsPerChannel) * driver.format.mChannelsPerFrame;
	driver.format.mBytesPerPacket = driver.format.mBytesPerFrame;

	// au graph
	FAILERR(0,NewAUGraph(&driver.graph),"FAILED: could not initialize new au graph");
	FAILERR(0,AUGraphAddNode(driver.graph, &outputDescription, &driver.outputNode),"FAILED: could not add node output");
	FAILERR(0,AUGraphAddNode(driver.graph, &mixerDescription, &driver.mixerNode),"FAILED: could not add node mixer");
	FAILERR(0,AUGraphConnectNodeInput(driver.graph, driver.mixerNode, 0, driver.outputNode, 0),"FAILED: could not connect node");
	FAILERR(0,AUGraphOpen(driver.graph),"FAILED: could not open graph");
	FAILERR(0,AUGraphNodeInfo(driver.graph, driver.mixerNode, NULL, &driver.mixerUnit),"FAILED: could not get mixer unit");

	// set the format & callback
	FAILERR(0,AudioUnitSetProperty(driver.mixerUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &driver.format, sizeof(driver.format)),"FAILED: could not set mixer unit input format");
	FAILERR(0,AudioUnitSetProperty(driver.mixerUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &driver.format, sizeof(driver.format)),"FAILED: could not set mixer unit output format");
	FAILERR(0,AUGraphSetNodeInputCallback(driver.graph, driver.mixerNode, 0, &callback),"FAILED: could not set mixer node callback");

	// initialize & start
	FAILERR(0,AUGraphInitialize(driver.graph),"FAILED: could not initialize au graph");
	FAILERR(0,AUGraphStart(driver.graph),"FAILED: could not start au graph");

	// create the secondary buffer we'll actually work with
	// QUAKE only supports 8-bit or 16-bit mixing
	dma.channels = 2;
	dma.samplebits = 16;
	dma.speed = driver.format.mSampleRate;
	dma.samples = DMA_BUFFER_SAMPLES;
	dma.submission_chunk = 0;
	dma.buffer = calloc(1, sizeofbits(dma.samplebits) * DMA_BUFFER_SAMPLES);

	return qtrue;
}

//==============================================================================

/*
==================
SNDDMA_Shutdown
==================
*/
void SNDDMA_Shutdown( void ) {
	Com_DPrintf( "Shutting down sound system\n" );

	if (driver.initialized) {
		Boolean isRunning = true;

		PRINTERR(0,AUGraphStop(driver.graph),"could not stop au graph");

		do {
			PRINTERR(0,AUGraphIsRunning(driver.graph, &isRunning),"could not validate running au graph");
		} while (isRunning);

		PRINTERR(0,AUGraphUninitialize(driver.graph),"could not uninitialize au graph");
		PRINTERR(0,AUGraphClose(driver.graph),"could not close au graph");
		PRINTERR(0,DisposeAUGraph(driver.graph),"could not dispose au graph");
		driver.graph = NULL;

		driver.chunkCount = 0;
		driver.initialized = qfalse;
		memset ((void *)&dma, 0, sizeof (dma));

		free(dma.buffer);
		dma.buffer = NULL;
	}
}

/*
==================
SNDDMA_Init

Initialize direct sound
Returns false if failed
==================
*/
qboolean SNDDMA_Init( void ) {

	memset ((void *)&dma, 0, sizeof (dma));
	driver.initialized = qfalse;

	if ( !SNDDMA_InitAUGraph () ) {
		return qfalse;
	}

	// initialize the driver in the IOProc
	//driver.initialized = qtrue;

	Com_DPrintf("Completed successfully\n" );

    return qtrue;
}

/*
==============
SNDDMA_GetDMAPos

return the current sample position (in mono samples read)
inside the recirculating dma buffer, so the mixing code will know
how many sample are required to fill it up.
===============
*/
int SNDDMA_GetDMAPos( void ) {
	if ( !driver.initialized ) {
		return 0;
	}

	return (driver.chunkCount * dma.submission_chunk);
}

/*
==============
SNDDMA_BeginPainting

Makes sure dma.buffer is valid
Unused on Mac OS X
===============
*/
void SNDDMA_BeginPainting( void ) {
}

/*
==============
SNDDMA_Submit

Send sound to device if buffer isn't really the dma buffer
Unused on Mac OS X
===============
*/
void SNDDMA_Submit( void ) {
}

/*
=================
SNDDMA_Activate

When we change windows we need to do this
Unused on Mac OS X
=================
*/
void SNDDMA_Activate( void ) {
}