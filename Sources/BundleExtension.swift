//
//  BundleExtension.swift
//  NextLevel
//
//  Created by Jaroslav Mach on 12/28/2020.
//  Copyright © 2020 ClassDojo. All rights reserved.
//

import Foundation

internal extension Bundle {
    #if IS_SPM
        static var NextLevelBundle: Bundle = Bundle.module
    #else
        static var NextLevelBundle: Bundle {
            guard let url = Bundle(for: NextLevel.self).url(forResource: "NextLevel", withExtension: "bundle"),
                  let resourcesBundle = Bundle(url: url)
            else {
                fatalError("NextLevel: Could not load the assets bundle")
            }
            return resourcesBundle
        }
    #endif
}
