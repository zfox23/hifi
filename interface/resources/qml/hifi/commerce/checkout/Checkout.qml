//
//  Checkout.qml
//  qml/hifi/commerce/checkout
//
//  Checkout
//
//  Created by Zach Fox on 2017-08-25
//  Copyright 2017 High Fidelity, Inc.
//
//  Distributed under the Apache License, Version 2.0.
//  See the accompanying file LICENSE or http://www.apache.org/licenses/LICENSE-2.0.html
//

import Hifi 1.0 as Hifi
import QtQuick 2.5
import QtQuick.Controls 1.4
import "../../../styles-uit"
import "../../../controls-uit" as HifiControlsUit
import "../../../controls" as HifiControls
import "../wallet" as HifiWallet
import "../common" as HifiCommerceCommon

// references XXX from root context

Rectangle {
    HifiConstants { id: hifi; }

    id: root;
    property string activeView: "initialize";
    property bool purchasesReceived: false;
    property bool balanceReceived: false;
    property bool securityImageResultReceived: false;
    property string itemId;
    property string itemPreviewImageUrl;
    property string itemHref;
    property double balanceAfterPurchase;
    property bool alreadyOwned: false;
    property int itemPrice: 0;
    property bool itemIsJson: true;
    property bool shouldBuyWithControlledFailure: false;
    property bool debugCheckoutSuccess: false;
    property bool canRezCertifiedItems: false;
    // Style
    color: hifi.colors.white;
    Hifi.QmlCommerce {
        id: commerce;

        onAccountResult: {
            if (result.status === "success") {
                commerce.getKeyFilePathIfExists();
            } else {
                // unsure how to handle a failure here. We definitely cannot proceed.
            }
        }

        onLoginStatusResult: {
            if (!isLoggedIn && root.activeView !== "needsLogIn") {
                root.activeView = "needsLogIn";
            } else if (isLoggedIn) {
                root.activeView = "initialize";
                commerce.account();
            }
        }

        onKeyFilePathIfExistsResult: {
            if (path === "" && root.activeView !== "notSetUp") {
                root.activeView = "notSetUp";
            } else if (path !== "" && root.activeView === "initialize") {
                commerce.getSecurityImage();
            }
        }

        onSecurityImageResult: {
            securityImageResultReceived = true;
            if (!exists && root.activeView !== "notSetUp") { // "If security image is not set up"
                root.activeView = "notSetUp";
            } else if (exists && root.activeView === "initialize") {
                commerce.getWalletAuthenticatedStatus();
            } else if (exists) {
                // just set the source again (to be sure the change was noticed)
                //securityImage.source = "";
                //securityImage.source = "image://security/securityImage";
            }
        }

        onWalletAuthenticatedStatusResult: {
            if (!isAuthenticated && root.activeView !== "passphraseModal") {
                root.activeView = "passphraseModal";
            } else if (isAuthenticated) {
                authSuccessStep();
            }
        }

        onBuyResult: {
            if (result.status !== 'success') {
                failureErrorText.text = "Here's some more info about the error:<br><br>" + (result.message);
                root.activeView = "checkoutFailure";
            } else {
                root.activeView = "checkoutSuccess";
            }
        }

        onBalanceResult: {
            if (result.status !== 'success') {
                console.log("Failed to get balance", result.data.message);
            } else {
                root.balanceReceived = true;
                root.balanceAfterPurchase = result.data.balance - root.itemPrice;
                root.setBuyText();
            }
        }

        onInventoryResult: {
            if (result.status !== 'success') {
                console.log("Failed to get purchases", result.data.message);
            } else {
                root.purchasesReceived = true;
                if (purchasesContains(result.data.assets, itemId)) {
                    root.alreadyOwned = true;
                } else {
                    root.alreadyOwned = false;
                }
                root.setBuyText();
            }
        }
    }

    HifiCommerceCommon.CommerceLightbox {
        id: lightboxPopup;
        visible: false;
        anchors.fill: parent;

        Connections {
            onSendToParent: {
                sendToScript(msg);
            }
        }
    }

    //
    // TITLE BAR START
    //
    HifiCommerceCommon.EmulatedMarketplaceHeader {
        id: titleBarContainer;
        z: 998;
        visible: !needsLogIn.visible;
        // Size
        width: parent.width;
        height: 70;
        // Anchors
        anchors.left: parent.left;
        anchors.top: parent.top;

        Connections {
            onSendToParent: {
                if (msg.method === 'needsLogIn' && root.activeView !== "needsLogIn") {
                    root.activeView = "needsLogIn";
                } else if (msg.method === 'showSecurityPicLightbox') {
                    lightboxPopup.titleText = "Your Security Pic";
                    lightboxPopup.bodyImageSource = msg.securityImageSource;
                    lightboxPopup.bodyText = lightboxPopup.securityPicBodyText;
                    lightboxPopup.button1text = "CLOSE";
                    lightboxPopup.button1method = "root.visible = false;"
                    lightboxPopup.button2text = "GO TO WALLET";
                    lightboxPopup.button2method = "sendToParent({method: 'checkout_openWallet'});";
                    lightboxPopup.visible = true;
                } else {
                    sendToScript(msg);
                }
            }
        }
    }
    //
    // TITLE BAR END
    //

    Rectangle {
        id: initialize;
        visible: root.activeView === "initialize";
        anchors.top: titleBarContainer.bottom;
        anchors.bottom: parent.top;
        anchors.left: parent.left;
        anchors.right: parent.right;
        color: hifi.colors.white;

        Component.onCompleted: {
            securityImageResultReceived = false;
            purchasesReceived = false;
            balanceReceived = false;
            commerce.getLoginStatus();
        }
    }

    HifiWallet.NeedsLogIn {
        id: needsLogIn;
        visible: root.activeView === "needsLogIn";
        anchors.top: parent.top;
        anchors.bottom: parent.bottom;
        anchors.left: parent.left;
        anchors.right: parent.right;

        Connections {
            onSendSignalToWallet: {
                sendToScript(msg);
            }
        }
    }
    Connections {
        target: GlobalServices
        onMyUsernameChanged: {
            commerce.getLoginStatus();
        }
    }

    HifiWallet.PassphraseModal {
        id: passphraseModal;
        visible: root.activeView === "passphraseModal";
        anchors.fill: parent;
        titleBarText: "Checkout";
        titleBarIcon: hifi.glyphs.wallet;

        Connections {
            onSendSignalToParent: {
                if (msg.method === "authSuccess") {
                    authSuccessStep();
                } else {
                    sendToScript(msg);
                }
            }
        }
    }

    //
    // "WALLET NOT SET UP" START
    //
    Item {
        id: notSetUp;
        visible: root.activeView === "notSetUp";
        anchors.top: titleBarContainer.bottom;
        anchors.bottom: parent.bottom;
        anchors.left: parent.left;
        anchors.right: parent.right;

        RalewayRegular {
            id: notSetUpText;
            text: "<b>Your wallet isn't set up.</b><br><br>Set up your Wallet (no credit card necessary) to claim your <b>free HFC</b> " +
            "and get items from the Marketplace.";
            // Text size
            size: 24;
            // Anchors
            anchors.top: parent.top;
            anchors.bottom: notSetUpActionButtonsContainer.top;
            anchors.left: parent.left;
            anchors.leftMargin: 16;
            anchors.right: parent.right;
            anchors.rightMargin: 16;
            // Style
            color: hifi.colors.black;
            wrapMode: Text.WordWrap;
            // Alignment
            horizontalAlignment: Text.AlignHCenter;
            verticalAlignment: Text.AlignVCenter;
        }

        Item {
            id: notSetUpActionButtonsContainer;
            // Size
            width: root.width;
            height: 70;
            // Anchors
            anchors.left: parent.left;
            anchors.bottom: parent.bottom;
            anchors.bottomMargin: 24;

            // "Cancel" button
            HifiControlsUit.Button {
                id: cancelButton;
                color: hifi.buttons.black;
                colorScheme: hifi.colorSchemes.light;
                anchors.top: parent.top;
                anchors.topMargin: 3;
                anchors.bottom: parent.bottom;
                anchors.bottomMargin: 3;
                anchors.left: parent.left;
                anchors.leftMargin: 20;
                width: parent.width/2 - anchors.leftMargin*2;
                text: "Cancel"
                onClicked: {
                    sendToScript({method: 'checkout_cancelClicked', params: itemId});
                }
            }

            // "Set Up" button
            HifiControlsUit.Button {
                id: setUpButton;
                color: hifi.buttons.blue;
                colorScheme: hifi.colorSchemes.light;
                anchors.top: parent.top;
                anchors.topMargin: 3;
                anchors.bottom: parent.bottom;
                anchors.bottomMargin: 3;
                anchors.right: parent.right;
                anchors.rightMargin: 20;
                width: parent.width/2 - anchors.rightMargin*2;
                text: "Set Up Wallet"
                onClicked: {
                    sendToScript({method: 'checkout_setUpClicked'});
                }
            }
        }
    }
    //
    // "WALLET NOT SET UP" END
    //

    //
    // CHECKOUT CONTENTS START
    //
    Item {
        id: checkoutContents;
        visible: root.activeView === "checkoutMain";
        anchors.top: titleBarContainer.bottom;
        anchors.bottom: parent.bottom;
        anchors.left: parent.left;
        anchors.right: parent.right;

        RalewayRegular {
            id: confirmPurchaseText;
            anchors.top: parent.top;
            anchors.topMargin: 30;
            anchors.left: parent.left;
            anchors.leftMargin: 16;
            width: paintedWidth;
            height: paintedHeight;
            text: "Confirm Purchase:";
            color: hifi.colors.baseGray;
            size: 28;
        }
        
        HifiControlsUit.Separator {
            id: separator;
            colorScheme: 1;
            anchors.left: parent.left;
            anchors.right: parent.right;
            anchors.top: confirmPurchaseText.bottom;
            anchors.topMargin: 16;
        }

        Item {
            id: itemContainer;
            anchors.top: separator.bottom;
            anchors.topMargin: 24;
            anchors.left: parent.left;
            anchors.leftMargin: 16;
            anchors.right: parent.right;
            anchors.rightMargin: 16;
            height: 120;

            Image {
                id: itemPreviewImage;
                source: root.itemPreviewImageUrl;
                anchors.left: parent.left;
                anchors.top: parent.top;
                anchors.bottom: parent.bottom;
                width: height;
                fillMode: Image.PreserveAspectCrop;
            }

            RalewaySemiBold {
                id: itemNameText;
                // Text size
                size: 26;
                // Anchors
                anchors.top: parent.top;
                anchors.left: itemPreviewImage.right;
                anchors.leftMargin: 12;
                anchors.right: itemPriceContainer.left;
                anchors.rightMargin: 8;
                height: 30;
                // Style
                color: hifi.colors.blueAccent;
                elide: Text.ElideRight;
                // Alignment
                horizontalAlignment: Text.AlignLeft;
                verticalAlignment: Text.AlignTop;
            }

            // "Item Price" container
            Item {
                id: itemPriceContainer;
                // Anchors
                anchors.top: parent.top;
                anchors.right: parent.right;
                height: 30;
                width: childrenRect.width;

                // "HFC" balance label
                HiFiGlyphs {
                    id: itemPriceTextLabel;
                    text: hifi.glyphs.hfc;
                    // Size
                    size: 36;
                    // Anchors
                    anchors.right: itemPriceText.left;
                    anchors.rightMargin: 4;
                    anchors.top: parent.top;
                    anchors.topMargin: -4;
                    width: paintedWidth;
                    height: paintedHeight;
                    // Style
                    color: hifi.colors.blueAccent;
                }
                FiraSansSemiBold {
                    id: itemPriceText;
                    text: "--";
                    // Text size
                    size: 26;
                    // Anchors
                    anchors.top: parent.top;
                    anchors.right: parent.right;
                    anchors.rightMargin: 16;
                    width: paintedWidth;
                    height: paintedHeight;
                    // Style
                    color: hifi.colors.blueAccent;
                }
            }
        }
        
        HifiControlsUit.Separator {
            id: separator2;
            colorScheme: 1;
            anchors.left: parent.left;
            anchors.right: parent.right;
            anchors.top: itemContainer.bottom;
            anchors.topMargin: itemContainer.anchors.topMargin;
        }


        //
        // ACTION BUTTONS AND TEXT START
        //
        Item {
            id: checkoutActionButtonsContainer;
            // Size
            width: root.width;
            // Anchors
            anchors.top: separator2.bottom;
            anchors.topMargin: 16;
            anchors.left: parent.left;
            anchors.leftMargin: 16;
            anchors.right: parent.right;
            anchors.rightMargin: 16;
            anchors.bottom: parent.bottom;
            anchors.bottomMargin: 8;

            Rectangle {
                id: buyTextContainer;
                visible: buyText.text !== "";
                anchors.top: parent.top;
                anchors.left: parent.left;
                anchors.right: parent.right;
                height: buyText.height + 30;
                radius: 4;
                border.width: 2;

                HiFiGlyphs {
                    id: buyGlyph;
                    // Size
                    size: 46;
                    // Anchors
                    anchors.left: parent.left;
                    anchors.leftMargin: 4;
                    anchors.top: parent.top;
                    anchors.topMargin: 8;
                    anchors.bottom: parent.bottom;
                    width: paintedWidth;
                    // Style
                    color: hifi.colors.baseGray;
                    // Alignment
                    horizontalAlignment: Text.AlignHCenter;
                    verticalAlignment: Text.AlignTop;
                }

                RalewaySemiBold {
                    id: buyText;
                    // Text size
                    size: 18;
                    // Anchors
                    anchors.left: buyGlyph.right;
                    anchors.leftMargin: 8;
                    anchors.right: parent.right;
                    anchors.rightMargin: 12;
                    anchors.verticalCenter: parent.verticalCenter;
                    height: paintedHeight;
                    // Style
                    color: hifi.colors.black;
                    wrapMode: Text.WordWrap;
                    // Alignment
                    horizontalAlignment: Text.AlignLeft;
                    verticalAlignment: Text.AlignVCenter;

                    onLinkActivated: {
                        sendToScript({method: 'checkout_goToPurchases', filterText: itemNameText.text});
                    }
                }
            }

            // "Buy" button
            HifiControlsUit.Button {
                id: buyButton;
                enabled: (root.balanceAfterPurchase >= 0 && purchasesReceived && balanceReceived) || !itemIsJson;
                color: hifi.buttons.blue;
                colorScheme: hifi.colorSchemes.light;
                anchors.top: buyTextContainer.visible ? buyTextContainer.bottom : checkoutActionButtonsContainer.top;
                anchors.topMargin: buyTextContainer.visible ? 12 : 16;
                height: 40;
                anchors.left: parent.left;
                anchors.right: parent.right;
                text: (itemIsJson ? ((purchasesReceived && balanceReceived) ? "Confirm Purchase" : "--") : "Get Item");
                onClicked: {
                    if (itemIsJson) {
                        buyButton.enabled = false;
                        if (!root.shouldBuyWithControlledFailure) {
                            commerce.buy(itemId, itemPrice);
                        } else {
                            commerce.buy(itemId, itemPrice, true);
                        }
                    } else {
                        if (urlHandler.canHandleUrl(itemHref)) {
                            urlHandler.handleUrl(itemHref);
                        }
                    }
                }
            }

            // "Cancel" button
            HifiControlsUit.Button {
                id: cancelPurchaseButton;
                color: hifi.buttons.noneBorderlessGray;
                colorScheme: hifi.colorSchemes.light;
                anchors.top: buyButton.bottom;
                anchors.topMargin: 16;
                height: 40;
                anchors.left: parent.left;
                anchors.right: parent.right;
                text: "Cancel"
                onClicked: {
                    sendToScript({method: 'checkout_cancelClicked', params: itemId});
                }
            }
        }
        //
        // ACTION BUTTONS END
        //
    }
    //
    // CHECKOUT CONTENTS END
    //

    //
    // CHECKOUT SUCCESS START
    //
    Item {
        id: checkoutSuccess;
        visible: root.activeView === "checkoutSuccess";
        anchors.top: titleBarContainer.bottom;
        anchors.bottom: root.bottom;
        anchors.left: parent.left;
        anchors.leftMargin: 16;
        anchors.right: parent.right;
        anchors.rightMargin: 16;

        RalewayRegular {
            id: completeText;
            anchors.top: parent.top;
            anchors.topMargin: 30;
            anchors.left: parent.left;
            width: paintedWidth;
            height: paintedHeight;
            text: "Thank you for your order!";
            color: hifi.colors.baseGray;
            size: 28;
        }

        RalewaySemiBold {
            id: completeText2;
            text: "The item " + '<font color="' + hifi.colors.blueAccent + '"><a href="#">' + itemNameText.text + '</a></font>' +
            " has been added to your Purchases and a receipt will appear in your Wallet's transaction history.";
            // Text size
            size: 20;
            // Anchors
            anchors.top: completeText.bottom;
            anchors.topMargin: 10;
            height: paintedHeight;
            anchors.left: parent.left;
            anchors.right: parent.right;
            // Style
            color: hifi.colors.black;
            wrapMode: Text.WordWrap;
            // Alignment
            horizontalAlignment: Text.AlignLeft;
            verticalAlignment: Text.AlignVCenter;
            onLinkActivated: {
                sendToScript({method: 'checkout_itemLinkClicked', itemId: itemId});
            }
        }
        
        Rectangle {
            id: rezzedNotifContainer;
            z: 997;
            visible: false;
            color: hifi.colors.blueHighlight;
            anchors.fill: rezNowButton;
            radius: 5;
            MouseArea {
                anchors.fill: parent;
                propagateComposedEvents: false;
            }

            RalewayBold {
                anchors.fill: parent;
                text: "REZZED";
                size: 18;
                color: hifi.colors.white;
                verticalAlignment: Text.AlignVCenter;
                horizontalAlignment: Text.AlignHCenter;
            }

            Timer {
                id: rezzedNotifContainerTimer;
                interval: 2000;
                onTriggered: rezzedNotifContainer.visible = false
            }
        }
        // "Rez" button
        HifiControlsUit.Button {
            id: rezNowButton;
            enabled: root.canRezCertifiedItems;
            buttonGlyph: hifi.glyphs.lightning;
            color: hifi.buttons.red;
            colorScheme: hifi.colorSchemes.light;
            anchors.top: completeText2.bottom;
            anchors.topMargin: 30;
            height: 50;
            anchors.left: parent.left;
            anchors.right: parent.right;
            text: "Rez It"
            onClicked: {
                if (urlHandler.canHandleUrl(itemHref)) {
                    urlHandler.handleUrl(itemHref);
                }
                rezzedNotifContainer.visible = true;
                rezzedNotifContainerTimer.start();
            }
        }
        RalewaySemiBold {
            id: noPermissionText;
            visible: !root.canRezCertifiedItems;
            text: '<font color="' + hifi.colors.redAccent + '"><a href="#">You do not have Certified Rez permissions in this domain.</a></font>'
            // Text size
            size: 16;
            // Anchors
            anchors.top: rezNowButton.bottom;
            anchors.topMargin: 4;
            height: paintedHeight;
            anchors.left: parent.left;
            anchors.right: parent.right;
            // Style
            color: hifi.colors.redAccent;
            wrapMode: Text.WordWrap;
            // Alignment
            horizontalAlignment: Text.AlignHCenter;
            verticalAlignment: Text.AlignVCenter;
            onLinkActivated: {
                lightboxPopup.titleText = "Rez Permission Required";
                lightboxPopup.bodyText = "You don't have permission to rez certified items in this domain.<br><br>" +
                    "Use the <b>GOTO app</b> to visit another domain or <b>go to your own sandbox.</b>";
                lightboxPopup.button1text = "CLOSE";
                lightboxPopup.button1method = "root.visible = false;"
                lightboxPopup.button2text = "OPEN GOTO";
                lightboxPopup.button2method = "sendToParent({method: 'purchases_openGoTo'});";
                lightboxPopup.visible = true;
            }
        }

        RalewaySemiBold {
            id: myPurchasesLink;
            text: '<font color="' + hifi.colors.blueAccent + '"><a href="#">View this item in My Purchases</a></font>';
            // Text size
            size: 20;
            // Anchors
            anchors.top: noPermissionText.visible ? noPermissionText.bottom : rezNowButton.bottom;
            anchors.topMargin: 40;
            height: paintedHeight;
            anchors.left: parent.left;
            anchors.right: parent.right;
            // Style
            color: hifi.colors.black;
            wrapMode: Text.WordWrap;
            // Alignment
            horizontalAlignment: Text.AlignLeft;
            verticalAlignment: Text.AlignVCenter;
            onLinkActivated: {
                sendToScript({method: 'checkout_goToPurchases'});
            }
        }

        RalewaySemiBold {
            id: walletLink;
            text: '<font color="' + hifi.colors.blueAccent + '"><a href="#">View receipt in Wallet</a></font>';
            // Text size
            size: 20;
            // Anchors
            anchors.top: myPurchasesLink.bottom;
            anchors.topMargin: 20;
            height: paintedHeight;
            anchors.left: parent.left;
            anchors.right: parent.right;
            // Style
            color: hifi.colors.black;
            wrapMode: Text.WordWrap;
            // Alignment
            horizontalAlignment: Text.AlignLeft;
            verticalAlignment: Text.AlignVCenter;
            onLinkActivated: {
                sendToScript({method: 'purchases_openWallet'});
            }
        }

        RalewayRegular {
            id: pendingText;
            text: 'Your item is marked "pending" while your purchase is being confirmed. ' +
            '<font color="' + hifi.colors.blueAccent + '"><a href="#">Learn More</a></font>';
            // Text size
            size: 20;
            // Anchors
            anchors.top: walletLink.bottom;
            anchors.topMargin: 60;
            height: paintedHeight;
            anchors.left: parent.left;
            anchors.right: parent.right;
            // Style
            color: hifi.colors.black;
            wrapMode: Text.WordWrap;
            // Alignment
            horizontalAlignment: Text.AlignLeft;
            verticalAlignment: Text.AlignVCenter;
            onLinkActivated: {
                lightboxPopup.titleText = "Purchase Confirmations";
                lightboxPopup.bodyText = 'Your item is marked "pending" while your purchase is being confirmed.<br><br>' +
                'Confirmations usually take about 90 seconds.';
                lightboxPopup.button1text = "CLOSE";
                lightboxPopup.button1method = "root.visible = false;"
                lightboxPopup.visible = true;
            }
        }

        // "Continue Shopping" button
        HifiControlsUit.Button {
            id: continueShoppingButton;
            color: hifi.buttons.noneBorderlessGray;
            colorScheme: hifi.colorSchemes.light;
            anchors.bottom: parent.bottom;
            anchors.bottomMargin: 20;
            anchors.right: parent.right;
            anchors.rightMargin: 14;
            width: parent.width/2 - anchors.rightMargin;
            height: 60;
            text: "Continue Shopping";
            onClicked: {
                sendToScript({method: 'checkout_continueShopping', itemId: itemId});
            }
        }
    }
    //
    // CHECKOUT SUCCESS END
    //

    //
    // CHECKOUT FAILURE START
    //
    Item {
        id: checkoutFailure;
        visible: root.activeView === "checkoutFailure";
        anchors.top: titleBarContainer.bottom;
        anchors.bottom: root.bottom;
        anchors.left: parent.left;
        anchors.right: parent.right;

        RalewayRegular {
            id: failureHeaderText;
            text: "<b>Purchase Failed.</b><br>Your Purchases and HFC balance haven't changed.";
            // Text size
            size: 24;
            // Anchors
            anchors.top: parent.top;
            anchors.topMargin: 80;
            height: paintedHeight;
            anchors.left: parent.left;
            anchors.right: parent.right;
            // Style
            color: hifi.colors.black;
            wrapMode: Text.WordWrap;
            // Alignment
            horizontalAlignment: Text.AlignHCenter;
            verticalAlignment: Text.AlignVCenter;
        }

        RalewayRegular {
            id: failureErrorText;
            // Text size
            size: 16;
            // Anchors
            anchors.top: failureHeaderText.bottom;
            anchors.topMargin: 35;
            height: paintedHeight;
            anchors.left: parent.left;
            anchors.right: parent.right;
            // Style
            color: hifi.colors.black;
            wrapMode: Text.WordWrap;
            // Alignment
            horizontalAlignment: Text.AlignHCenter;
            verticalAlignment: Text.AlignVCenter;
        }

        Item {
            id: backToMarketplaceButtonContainer;
            // Size
            width: root.width;
            height: 130;
            // Anchors
            anchors.left: parent.left;
            anchors.bottom: parent.bottom;
            anchors.bottomMargin: 8;
            // "Back to Marketplace" button
            HifiControlsUit.Button {
                id: backToMarketplaceButton;
                color: hifi.buttons.black;
                colorScheme: hifi.colorSchemes.light;
                anchors.top: parent.top;
                anchors.topMargin: 3;
                anchors.bottom: parent.bottom;
                anchors.bottomMargin: 3;
                anchors.right: parent.right;
                anchors.rightMargin: 20;
                width: parent.width/2 - anchors.rightMargin*2;
                text: "Back to Marketplace";
                onClicked: {
                    sendToScript({method: 'checkout_continueShopping', itemId: itemId});
                }
            }
        }
    }
    //
    // CHECKOUT FAILURE END
    //

    Keys.onPressed: {
        if ((event.key == Qt.Key_F) && (event.modifiers & Qt.ControlModifier)) {
            if (!root.shouldBuyWithControlledFailure) {
                buyButton.text += " DEBUG FAIL ON"
                buyButton.color = hifi.buttons.red;
                root.shouldBuyWithControlledFailure = true;
            } else {
                buyButton.text = (itemIsJson ? ((purchasesReceived && balanceReceived) ? (root.alreadyOwned ? "Buy Another" : "Buy"): "--") : "Get Item");
                buyButton.color = hifi.buttons.blue;
                root.shouldBuyWithControlledFailure = false;
            }
        }
    }

    //
    // FUNCTION DEFINITIONS START
    //
    //
    // Function Name: fromScript()
    //
    // Relevant Variables:
    // None
    //
    // Arguments:
    // message: The message sent from the JavaScript, in this case the Marketplaces JavaScript.
    //     Messages are in format "{method, params}", like json-rpc.
    //
    // Description:
    // Called when a message is received from a script.
    //
    function fromScript(message) {
        switch (message.method) {
            case 'updateCheckoutQML':
                itemId = message.params.itemId;
                itemNameText.text = message.params.itemName;
                root.itemPrice = message.params.itemPrice;
                itemPriceText.text = root.itemPrice === 0 ? "Free" : root.itemPrice;
                itemHref = message.params.itemHref;
                itemPreviewImageUrl = "https://hifi-metaverse.s3-us-west-1.amazonaws.com/marketplace/previews/" + itemId + "/thumbnail/hifi-mp-" + itemId + ".jpg";
                if (itemHref.indexOf('.json') === -1) {
                    root.itemIsJson = false;
                }
                root.canRezCertifiedItems = message.canRezCertifiedItems;
                setBuyText();
            break;
            default:
                console.log('Unrecognized message from marketplaces.js:', JSON.stringify(message));
        }
    }
    signal sendToScript(var message);

    function purchasesContains(purchasesJson, id) {
        for (var idx = 0; idx < purchasesJson.length; idx++) {
            if(purchasesJson[idx].id === id) {
                return true;
            }
        }
        return false;
    }

    function setBuyText() {
        if (root.itemIsJson) {
            if (root.purchasesReceived && root.balanceReceived) {
                if (root.balanceAfterPurchase < 0) {
                    if (root.alreadyOwned) {
                        buyText.text = "Your Wallet does not have sufficient funds to purchase this item again.<br>" +
                        '<font color="' + hifi.colors.blueAccent + '"><a href="#">View the copy you own in My Purchases</a></font>';
                    } else {
                        buyText.text = "Your Wallet does not have sufficient funds to purchase this item.";
                    }
                    buyTextContainer.color = "#FFC3CD";
                    buyTextContainer.border.color = "#F3808F";
                    buyGlyph.text = hifi.glyphs.error;
                    buyGlyph.size = 54;
                } else {
                    if (root.alreadyOwned) {
                        buyText.text = 'You already own this item.<br>Purchasing it will buy another copy.<br><font color="'
                        + hifi.colors.blueAccent + '"><a href="#">View this item in My Purchases</a></font>';
                        buyTextContainer.color = "#FFD6AD";
                        buyTextContainer.border.color = "#FAC07D";
                        buyGlyph.text = hifi.glyphs.alert;
                        buyGlyph.size = 46;
                    } else {
                        buyText.text = "";
                    }
                }
            } else {
                buyText.text = "";
            }
        } else {
            buyText.text = "This Marketplace item isn't an entity. It <b>will not</b> be added to your <b>Purchases</b>.";
            buyTextContainer.color = "#FFD6AD";
            buyTextContainer.border.color = "#FAC07D";
            buyGlyph.text = hifi.glyphs.alert;
            buyGlyph.size = 46;
        }
    }

    function authSuccessStep() {
        if (!root.debugCheckoutSuccess) {
            root.activeView = "checkoutMain";
        } else {
            root.activeView = "checkoutSuccess";
        }
        if (!balanceReceived) {
            commerce.balance();
        }
        if (!purchasesReceived) {
            commerce.inventory();
        }
    }

    //
    // FUNCTION DEFINITIONS END
    //
}
