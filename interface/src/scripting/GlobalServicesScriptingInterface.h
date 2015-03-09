//
//  GlobalServicesScriptingInterface.h
//  interface/src/scripting
//
//  Created by Thijs Wenker on 9/10/14.
//  Copyright 2014 High Fidelity, Inc.
//
//  Distributed under the Apache License, Version 2.0.
//  See the accompanying file LICENSE or http://www.apache.org/licenses/LICENSE-2.0.html
//

#ifndef hifi_GlobalServicesScriptingInterface_h
#define hifi_GlobalServicesScriptingInterface_h

#include <QObject>
#include <QScriptContext>
#include <QScriptEngine>
#include <QScriptValue>
#include <QString>
#include <QStringList>

class DownloadInfoResult {
public:
    DownloadInfoResult();
    QList<float> downloading;  // List of percentages
    float pending;
};

Q_DECLARE_METATYPE(DownloadInfoResult)

QScriptValue DownloadInfoResultToScriptValue(QScriptEngine* engine, const DownloadInfoResult& result);
void DownloadInfoResultFromScriptValue(const QScriptValue& object, DownloadInfoResult& result);

class GlobalServicesScriptingInterface : public QObject {
    Q_OBJECT
    
    Q_PROPERTY(QString username READ getUsername)
    
public:
    static GlobalServicesScriptingInterface* getInstance();

    const QString& getUsername() const { return AccountManager::getInstance().getAccountInfo().getUsername(); }
    
public slots:
    DownloadInfoResult getDownloadInfo();
    void updateDownloadInfo();
    
    void setDiscoverability(const QString& discoverability);

private slots:
    void loggedOut();
    void checkDownloadInfo();

signals:
    void connected();
    void disconnected(const QString& reason);
    void myUsernameChanged(const QString& username);
    void downloadInfoChanged(DownloadInfoResult info);

private:
    GlobalServicesScriptingInterface();
    ~GlobalServicesScriptingInterface();
    
    bool _downloading;
};

#endif // hifi_GlobalServicesScriptingInterface_h
