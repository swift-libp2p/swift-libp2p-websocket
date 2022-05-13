//
//  Application+WS.swift
//  
//
//  Created by Brandon Toms on 5/10/22.
//

import LibP2P

extension Application {
    public var ws: WS {
        .init(application: self)
    }

    public struct WS {
        public let application: Application
    }
}
