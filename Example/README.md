# PUSHED Messaging iOS Library - Example App

Это пример приложения, демонстрирующий использование PUSHED Messaging iOS Library с поддержкой Notification Service Extension.

## 🚀 Быстрый старт

### 1. Создание Notification Service Extension Target

**Важно:** Для полной функциональности сначала создайте target для AppNotiService:

🚀 **[Quick Start Guide (5 минут) →](QUICK_START.md)**  
📋 **[Подробная инструкция по настройке →](SETUP_EXTENSION.md)**

Краткие шаги:
1. Откройте `PushedMessagingiOSLibrary.xcworkspace` в Xcode
2. Создайте новый target: iOS → Application Extension → Notification Service Extension
3. Замените автосгенерированные файлы на файлы из папки `AppNotiService/`
4. Настройте App Groups для обоих targets
5. Соберите проект

### 2. Альтернатива: Быстрая настройка

```bash
cd Example
./setup_extension.sh
```

## Компоненты

### Основное приложение
- **Логотип PUSHED** - в верхней части экрана
- **Service status: Active** - статус сервиса (зеленый текст)
- **Client token** - отображение клиентского токена 
- **Кнопка "Copy token"** - для копирования токена в буфер обмена

### Notification Service Extension (AppNotiService)
- Автоматическое подтверждение push-уведомлений в фоне
- Отправка событий взаимодействия с уведомлениями
- Shared UserDefaults для обмена токеном с основным приложением

## Новые возможности

### App Groups Integration
Основное приложение и extension используют shared UserDefaults для обмена данными:

```swift
// Настройка App Group
PushedMessagingiOSLibrary.configureAppGroup("group.pushed.example")

// Включение обработки через extension
PushedMessagingiOSLibrary.extensionHandlesConfirmation = true
```

### Automatic Message Confirmation
Extension автоматически обрабатывает:
- Подтверждение получения push-уведомлений
- Отправку SHOW событий
- Обработку interaction events

## Добавление логотипа PUSHED

Чтобы добавить логотип PUSHED:

1. Подготовьте изображение логотипа в форматах:
   - `pushed-logo.png` (1x)
   - `pushed-logo@2x.png` (2x) 
   - `pushed-logo@3x.png` (3x)

2. Добавьте файлы изображений в папку:
   ```
   PushedMessagingiOSLibrary/Images.xcassets/pushed-logo.imageset/
   ```

3. Обновите файл `Contents.json` в той же папке, указав имена файлов:
   ```json
   {
     "images" : [
       {
         "idiom" : "universal",
         "filename" : "pushed-logo.png",
         "scale" : "1x"
       },
       {
         "idiom" : "universal", 
         "filename" : "pushed-logo@2x.png",
         "scale" : "2x"
       },
       {
         "idiom" : "universal",
         "filename" : "pushed-logo@3x.png", 
         "scale" : "3x"
       }
     ],
     "info" : {
       "author" : "xcode",
       "version" : 1
     }
   }
   ```

## Настройка

### Основное приложение

Библиотека инициализируется в `AppDelegate.swift`:

```swift
// Настройка App Group (до setup!)
PushedMessagingiOSLibrary.configureAppGroup("group.pushed.example")

// Указываем, что extension обрабатывает подтверждения
PushedMessagingiOSLibrary.extensionHandlesConfirmation = true

// Основная настройка
PushedMessagingiOSLibrary.setup(self)
```

### App Groups Setup

Убедитесь, что оба entitlements файла содержат одинаковый App Group:

**PushedMessagingiOSLibrary_Example.entitlements:**
```xml
<key>com.apple.security.application-groups</key>
<array>
    <string>group.pushed.example</string>
</array>
```

**AppNotiService.entitlements:**
```xml
<key>com.apple.security.application-groups</key>
<array>
    <string>group.pushed.example</string>
</array>
```

## Функциональность

- **Автоматическое получение токена**: После инициализации библиотеки токен отображается автоматически
- **Копирование токена**: Нажатие на кнопку копирует токен в буфер обмена
- **Обратная связь**: Кнопка показывает "✓ Copied!" после успешного копирования
- **Статус сервиса**: Показывает "Active" зеленым цветом
- **Background processing**: Extension обрабатывает уведомления в фоне
- **Automatic confirmation**: Подтверждения отправляются автоматически через extension

## Подробная документация

См. [AppNotiService/README.md](AppNotiService/README.md) для детальной информации о настройке и использовании Notification Service Extension. 