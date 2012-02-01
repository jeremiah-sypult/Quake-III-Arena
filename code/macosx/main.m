//
//  main.m
//  quake3
//
//  Created by Jeremiah Sypult on 1/26/12.
//  Copyright (c) 2012 __MyCompanyName__. All rights reserved.
//

#import <Cocoa/Cocoa.h>

int main(int argc, char *argv[])
{
#ifdef DEDICATED
    Q3Controller *controller;
    
    stdin_active = qtrue;
    controller = [[Q3Controller alloc] init];
    [controller quakeMain];
    return 0;
#else
	return NSApplicationMain(argc, (const char **)argv);
#endif
}
