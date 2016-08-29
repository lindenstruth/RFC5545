//
//  RFC5545.swift
//
//  Copyright © 2016 Gargoyle Software, LLC.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.
//

import Foundation
import EventKit

public enum RFC5545Exception : ErrorType {
    case MissingStartDate
    case MissingEndDate
    case MissingSummary
    case InvalidRecurrenceRule
    case InvalidDateFormat
    case UnsupportedRecurrenceProperty
}

/// Parses a date string and determines whether or not it includes a time component.
///
/// - Parameter str: The date string to parse.
/// - Returns: A tuple containing the `NSDate` as well as a `Bool` specifying whether or not there is a time component.
/// - Throws: `RFC5545Exception.InvalidDateFormat`: The date is not in a correct format.
/// - SeeAlso: [RFC5545 Date](http://google-rfc-2445.googlecode.com/svn/trunk/RFC5545.html#4.3.4)
/// - SeeAlso: [RFC5545 Date-Time](http://google-rfc-2445.googlecode.com/svn/trunk/RFC5545.html#4.3.5)
/// - Note: If a time is not specified in the input, the time of the returned `NSDate` is set to noon.
func parseDateString(str: String) throws -> (date: NSDate, hasTimeComponent: Bool) {
    var dateStr: String!
    var options: [String : String] = [:]

    let delim = NSCharacterSet(charactersInString: ";:")
    for param in str.componentsSeparatedByCharactersInSet(delim) {
        let keyValuePair = param.componentsSeparatedByString("=")
        if keyValuePair.count == 1 {
            dateStr = keyValuePair[0]
        } else {
            options[keyValuePair[0]] = keyValuePair[1]
        }
    }

    if dateStr == nil && options.isEmpty {
        dateStr = str
    }

    let components = NSDateComponents()

    let needsTime: Bool
    if let value = options["VALUE"] {
        needsTime = value != "DATE"
    } else {
        needsTime = true
    }

    var year = 0
    var month = 0
    var day = 0
    var hour = 0
    var minute = 0
    var second = 0

    var args: [CVarArgType] = []

    withUnsafeMutablePointers(&year, &month, &day) {
        y, m, d in
        args.append(y)
        args.append(m)
        args.append(d)
    }

    if needsTime {
        withUnsafeMutablePointers(&hour, &minute, &second) {
            h, m, s in
            args.append(h)
            args.append(m)
            args.append(s)
        }

        if let tzid = options["TZID"], tz = NSTimeZone(name: tzid) {
            components.timeZone = tz
        } else {
            throw RFC5545Exception.InvalidDateFormat
        }

        if dateStr.characters.last! == "Z" {
            guard components.timeZone == nil else { throw RFC5545Exception.InvalidDateFormat }
            components.timeZone = NSTimeZone(forSecondsFromGMT: 0)
        }

        if vsscanf(dateStr, "%4d%2d%2dT%2d%2d%2d", getVaList(args)) == 6 {
            components.year = year
            components.month = month
            components.day = day
            components.hour = hour
            components.minute = minute
            components.second = second

            if let date = NSCalendar.currentCalendar().dateFromComponents(components) {
                return (date: date, hasTimeComponent: true)
            }
        }
    } else if vsscanf(dateStr, "%4d%2d%2d", getVaList(args)) == 3 {
        components.year = year
        components.month = month
        components.day = day

        if let date = NSCalendar.currentCalendar().dateFromComponents(components) {
            return (date: date, hasTimeComponent: false)
        }
    }

    throw RFC5545Exception.InvalidDateFormat
}


/// An object representing an RFC5545 compatible date.  The full RFC5545 spec is *not* implemented here.
/// This only represents those properties which relate to an `EKEvent`.
class RFC5545 {
    var startDate: NSDate!
    var endDate: NSDate!
    var summary: String!
    var notes: String?
    var location: String?
    var recurrenceRules: [EKRecurrenceRule]?
    var url: NSURL?
    var exclusions: [NSDate]?
    var allDay = false

    init(string: String) throws {
        let regex = try! NSRegularExpression(pattern: "\r\n[ \t]+", options: [])
        let lines = regex
            .stringByReplacingMatchesInString(string, options: [], range: NSMakeRange(0, string.characters.count), withTemplate: "")
            .componentsSeparatedByString("\r\n")

        exclusions = []
        recurrenceRules = []

        var startHasTimeComponent = false
        var endHasTimeComponent = false

        for line in lines {
            if line.hasPrefix("DTSTART:") || line.hasPrefix(("DTSTART;")) {
                let dateInfo = try parseDateString(line)
                startDate = dateInfo.date
                startHasTimeComponent = dateInfo.hasTimeComponent
            } else if line.hasPrefix("DTEND:") || line.hasPrefix(("DTEND;")) {
                let dateInfo = try parseDateString(line)
                endDate = dateInfo.date
                endHasTimeComponent = dateInfo.hasTimeComponent
            } else if line.hasPrefix("URL:") || line.hasPrefix(("URL;")) {
                if let text = unescape(text: line, startingAt: 4) {
                    url = NSURL(string: text)
                }
            } else if line.hasPrefix("SUMMARY:") {
                // This is the Subject of the event
                summary = unescape(text: line, startingAt: 8)
            } else if line.hasPrefix("DESCRIPTION:") {
                // This is the Notes of the event.
                notes = unescape(text: line, startingAt: 12)
            } else if line.hasPrefix("LOCATION:") {
                location = unescape(text: line, startingAt: 9)
            } else if line.hasPrefix("RRULE:") {
                let rule = try EKRecurrenceRule(rrule: line)
                recurrenceRules!.append(rule)
            } else if line.hasPrefix("EXDATE:") || line.hasPrefix("EXDATE;") {
                let dateInfo = try parseDateString(line)
                exclusions!.append(dateInfo.date)
            }
        }

        guard startDate != nil else {
            throw RFC5545Exception.MissingStartDate
        }

        if exclusions!.isEmpty {
            exclusions = nil
        }

        if recurrenceRules!.isEmpty {
            recurrenceRules = nil
        }

        if !(startHasTimeComponent || endHasTimeComponent) {
            allDay = true
        } else if endDate == nil {
            if startHasTimeComponent {
                // For cases where a "VEVENT" calendar component specifies a "DTSTART" property with a DATE-TIME
                // data type but no "DTEND" property, the event ends on the same calendar date and time of day
                // specified by the "DTSTART" property.
                endDate = startDate
            } else {
                // For cases where a "VEVENT" calendar component specifies a "DTSTART" property with a DATE
                // data type but no "DTEND" property, the events non-inclusive end is the end of the calendar
                // date specified by the "DTSTART" property.
                let calendar = NSCalendar.currentCalendar()
                let components = calendar.components([.Era, .Year, .Month, .Day], fromDate: startDate)
                components.hour = 23
                components.minute = 59
                components.second = 59

                endDate = calendar.dateFromComponents(components)
            }
        }
    }

    /// Unescapes the TEXT type blocks to remove the \ characters that were added in.
    ///
    /// - Parameter text: The text to unescape.
    /// - Parameter startingAt: The position in the string to start unescaping.
    /// - SeeAlso: [RFC5545 TEXT](http://google-rfc-2445.googlecode.com/svn/trunk/RFC5545.html#4.3.11)
    /// - Returns: The unescaped text or `nil` if there is no text after the indicated start position.
    private func unescape(text text: String, startingAt: Int) -> String? {
        guard text.characters.count > startingAt else { return nil }

        return text
            .substringFromIndex(text.startIndex.advancedBy(startingAt))
            .stringByReplacingOccurrencesOfString("\\;", withString: ";")
            .stringByReplacingOccurrencesOfString("\\,", withString: ",")
            .stringByReplacingOccurrencesOfString("\\\\", withString: "\\")
            .stringByReplacingOccurrencesOfString("\\n", withString: "\n")
    }

    /// Generates an `EKEvent` from this object.
    ///
    /// - Parameter store: The `EKEventStore` to which the event belongs.
    /// - Parameter calendar: The `EKCalendar` in which to create the event.
    /// - Warning: While the RFC5545 spec allows multiple recurrence rules, iOS currently only honors the last rule.
    /// - Returns: The created event.
    func EKEvent(store: EKEventStore, calendar: EKCalendar?) -> EventKit.EKEvent {
        let event = EventKit.EKEvent(eventStore: store)
        event.startDate = startDate
        event.endDate = endDate
        event.notes = notes
        event.location = location
        
        if let calendar = calendar {
            event.calendar = calendar
        }
        
        if let title = summary {
            event.title = title
        }
        
        event.allDay = allDay
        event.URL = url
        
        recurrenceRules?.forEach {
            event.addRecurrenceRule($0)
        }
        
        return event
    }
}

