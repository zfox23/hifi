//
//  Separator.qml
//
//  Created by Zach Fox on 2017-06-06
//  Copyright 2017 High Fidelity, Inc.
//
//  Distributed under the Apache License, Version 2.0.
//  See the accompanying file LICENSE or http://www.apache.org/licenses/LICENSE-2.0.html
//

import QtQuick 2.5
import "../styles-uit"

Item {
    property int colorScheme: 0;
    
    readonly property var topColor: [ hifi.colors.baseGrayShadow, hifi.colors.lightGray50 ];
    readonly property var bottomColor: [ hifi.colors.baseGrayHighlight, hifi.colors.lightGray50 ];

    // Size
    height: 2;
    Rectangle {
        // Size
        width: parent.width;
        height: 1;
        // Anchors
        anchors.left: parent.left;
        anchors.bottom: parent.bottom;
        anchors.bottomMargin: height;
        // Style
        color: topColor[colorScheme];
    }
    Rectangle {
        // Size
        width: parent.width;
        height: 1;
        // Anchors
        anchors.left: parent.left;
        anchors.bottom: parent.bottom;
        // Style
        color: bottomColor[colorScheme];
    }
}
