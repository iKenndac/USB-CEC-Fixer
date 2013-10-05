//
//  DKAppDelegate.m
//  USBCECFixer
//
//  Created by Daniel Kennett on 05/10/2013.
//  Copyright (c) 2013 Daniel Kennett. All rights reserved.
//

#import "DKAppDelegate.h"
#import <IOKit/IOKitLib.h>
#import <IOKit/IOMessage.h>
#import <IOKit/IOCFPlugIn.h>
#import <IOKit/usb/IOUSBLib.h>
#import <IOKit/serial/IOSerialKeys.h>

@implementation DKAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification
{
	// Insert code here to initialize your application
	bool foundBySerial = findCECDeviceBySerialService();

	if (!foundBySerial) {

		printf("Don't have device by serial.\n");

		bool foundByUSB = findCECDeviceOnBus(false);

		if (!foundByUSB) {
			printf("Not found on USB bus either — never mind.\n");
			return;
		}

		bool wasReset = findCECDeviceOnBus(true);

		if (!wasReset) {
			printf("Resetting failed.\n");
			return;
		}

		// It takes a little while for the system to find the device again after reset,
		// so wait a second then look again.
		[self performSelector:@selector(continueCECSearch) withObject:Nil afterDelay:1.0];

	}

}

-(void)continueCECSearch {

    bool foundAgainBySerial = findCECDeviceBySerialService();
    
    if (foundAgainBySerial)
        printf("Found device by serial. Hooray! \n");
    else
        printf("Still can't find by serial :-( \n");

}

#define CEC_VID  0x2548
#define CEC_PID  0x1001
#define CEC_PID2 0x1002

bool findCECDeviceOnBus(bool resetDeviceIfFound) {

	mach_port_t masterPort;
    kern_return_t kernResult = KERN_SUCCESS;
    io_iterator_t intfIterator;

    kernResult = IOMasterPort(bootstrap_port, &masterPort);
    if (KERN_SUCCESS != kernResult)
        printf("IOMasterPort returned 0x%08x\n", kernResult);

	CFDictionaryRef ref = IOServiceMatching(kIOUSBDeviceClassName);
	if (!ref) {
		printf("%s(): IOServiceMatching returned a NULL dictionary.\n", __func__);
		return NO;
	}

	kernResult = IOServiceGetMatchingServices(masterPort, ref, &intfIterator);
	if (KERN_SUCCESS != kernResult)
        NSLog(@"IOServiceGetMatchingServices returned 0x%08x\n", kernResult);


	bool retValue = findCECDeviceOnUSBPlane(intfIterator, resetDeviceIfFound);

	IOObjectRelease(intfIterator);

	return retValue;
}

bool findCECDeviceOnUSBPlane(io_iterator_t iterator, bool resetDeviceIfFound) {

	io_service_t serviceObject;
	IOCFPlugInInterface **plugInInterface = NULL;
	IOUSBDeviceInterface187 **dev = NULL;
	SInt32 score;
	kern_return_t kr;
	HRESULT result;
	CFMutableDictionaryRef entryProperties = NULL;

	while ((serviceObject = IOIteratorNext(iterator))) {
		IORegistryEntryCreateCFProperties(serviceObject, &entryProperties, NULL, 0);

		kr = IOCreatePlugInInterfaceForService(serviceObject,
											   kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID,
											   &plugInInterface, &score);

		if ((kr != kIOReturnSuccess) || !plugInInterface) {
			printf("%s(): Unable to create a plug-in (%08x)\n", __func__, kr);
			continue;
		}

		// create the device interface
		result = (*plugInInterface)->QueryInterface(plugInInterface,
													CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID),
													(LPVOID *)&dev);

		// don’t need the intermediate plug-in after device interface is created
		(*plugInInterface)->Release(plugInInterface);

		if (result || !dev) {
			printf("%s(): Couldn’t create a device interface (%08x)\n", __func__, (int) result);
			continue;
		}

		UInt16 vendorID, productID;
		(*dev)->GetDeviceVendor(dev, &vendorID);
		(*dev)->GetDeviceProduct(dev, &productID);

		if (vendorID == CEC_VID && (productID == CEC_PID || productID == CEC_PID2)) {

			if (!resetDeviceIfFound) return true;

			kr = (*dev)->USBDeviceOpen(dev);
			if (kr != kIOReturnSuccess)
				return false;

			kr = (*dev)->ResetDevice(dev);
			if (kr != kIOReturnSuccess)
				return false;

			kr = (*dev)->USBDeviceReEnumerate(dev, 0);
			if (kr != kIOReturnSuccess)
				return false;

			kr = (*dev)->USBDeviceClose(dev);
			if (kr != kIOReturnSuccess) {
				printf("Closing failed\n");
				return true;
			}

			return true;
		}
	}

	return false;
}


bool findCECDeviceBySerialService() {

	// This is just a copypaste of the device finding code in libCEC.

	kern_return_t	kresult;
	char bsdPath[MAXPATHLEN] = {0};
	io_iterator_t	serialPortIterator;

	CFMutableDictionaryRef classesToMatch = IOServiceMatching(kIOSerialBSDServiceValue);
	if (classesToMatch)
	{
		CFDictionarySetValue(classesToMatch, CFSTR(kIOSerialBSDTypeKey), CFSTR(kIOSerialBSDModemType));
		kresult = IOServiceGetMatchingServices(kIOMasterPortDefault, classesToMatch, &serialPortIterator);
		if (kresult == KERN_SUCCESS)
		{
			io_object_t serialService;
			while ((serialService = IOIteratorNext(serialPortIterator)))
			{
				int iVendor = 0, iProduct = 0;
				CFTypeRef	bsdPathAsCFString;

				// fetch the device path.
				bsdPathAsCFString = IORegistryEntryCreateCFProperty(serialService,
																	CFSTR(kIOCalloutDeviceKey), kCFAllocatorDefault, 0);
				if (bsdPathAsCFString)
				{
					// convert the path from a CFString to a C (NUL-terminated) string.
					CFStringGetCString((CFStringRef)bsdPathAsCFString, bsdPath, MAXPATHLEN - 1, kCFStringEncodingUTF8);
					CFRelease(bsdPathAsCFString);

					// now walk up the hierarchy until we find the entry with vendor/product IDs
					io_registry_entry_t parent;
					CFTypeRef vendorIdAsCFNumber  = NULL;
					CFTypeRef productIdAsCFNumber = NULL;
					kern_return_t kresult = IORegistryEntryGetParentEntry(serialService, kIOServicePlane, &parent);
					while (kresult == KERN_SUCCESS)
					{
						vendorIdAsCFNumber  = IORegistryEntrySearchCFProperty(parent,
																			  kIOServicePlane, CFSTR(kUSBVendorID),  kCFAllocatorDefault, 0);
						productIdAsCFNumber = IORegistryEntrySearchCFProperty(parent,
																			  kIOServicePlane, CFSTR(kUSBProductID), kCFAllocatorDefault, 0);
						if (vendorIdAsCFNumber && productIdAsCFNumber)
						{
							CFNumberGetValue((CFNumberRef)vendorIdAsCFNumber, kCFNumberIntType, &iVendor);
							CFRelease(vendorIdAsCFNumber);
							CFNumberGetValue((CFNumberRef)productIdAsCFNumber, kCFNumberIntType, &iProduct);
							CFRelease(productIdAsCFNumber);
							IOObjectRelease(parent);
							break;
						}
						io_registry_entry_t oldparent = parent;
						kresult = IORegistryEntryGetParentEntry(parent, kIOServicePlane, &parent);
						IOObjectRelease(oldparent);
					}
					if (strlen(bsdPath) && iVendor == CEC_VID && (iProduct == CEC_PID || iProduct == CEC_PID2))
					{
						return true;
					}
				}
				IOObjectRelease(serialService);
			}
		}
		IOObjectRelease(serialPortIterator);
	}

	return false;

}



@end
