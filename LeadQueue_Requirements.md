# Lead Queue Requirements - Current Implementation

## Overview
The Lead Queue is a modern Lightning Web Component (LWC) system that replaced the legacy DICE Queue Visualforce page. It provides a comprehensive intake management solution for Worker Compensation and Personal Injury leads with priority-based assignment and real-time tracking.

## ✅ IMPLEMENTED FEATURES

### Core Components
- **Lightning Web Component**: Modern `leadQueueViewer` component with dual interface modes
- **Assignment System**: Platform cache-based record locking with 30-minute TTL
- **Priority Engine**: Multi-factor prioritization based on status, case type, and timing
- **Real-time Updates**: Live assignment tracking and queue refreshing every 30 seconds
- **Console Integration**: Optimized navigation for Salesforce Console apps

### Processing Cycle
1. **Lead Creation** → appears in queue immediately based on eligibility criteria
2. **Call Logging** → automation updates `Call_at_Date__c` (next call in 3 hours if no answer)
3. **Appointment Scheduling** → `Call_at_Date__c` becomes appointment date
4. **Automatic Prioritization** → priority system based on status and case type
5. **Assignment Tracking** → 30-minute platform cache TTL with auto-release

### Queue Management
- **Assignment Control**: "Get Next Record" assigns highest priority available record
- **Record Locking**: Assigned records temporarily removed from queue visibility
- **Auto-Release**: Records auto-released when key fields change or after 30 minutes
- **Re-entry Logic**: Records can reappear if they continue to meet qualifying conditions
- **Cross-Component Sync**: Assignment status synced across all interface components

---

## Technical Implementation

### Priority System

**Primary Priority** - Based on Intake Status (`litify_pm__Status__c`):
1. **Lead Generated** (Priority 1) ✅
2. **Intake Scheduled** (Priority 2) ✅
3. **In Contact/Under Review** (Priority 3) ✅
4. **Missed Appointment** (Priority 4) ✅
5. **Intake Package Sent** (Priority 5) ✅
6. **Attempting to Contact** (Priority 6) ✅
7. **Questionnaire** (Priority 7) ✅

**Secondary Priority** - Sub-sorted by Case Type Reporting (`Case_Type_Reporting__c`) *(Updated September 2025)*:
1. **Labor Law** (Priority 1) ✅
2. **MVA** (Priority 2) ✅
3. **Premises** (Priority 3) ✅
4. **WC & PI** (Priority 4) ✅
5. **Personal Injury** (Priority 5) ✅
6. **Worker Compensation** (Priority 6) ✅
7. **Other** (Priority 7) ✅
8. **NULL** (Priority 8) ✅
9. **Medical Malpractice** (Priority 9) *New*
10. **Employment Law** (Priority 10) *New*
11. **Federal Workers' Compensation** (Priority 11) *New*
12. **Immigration** (Priority 12) *New*
13. **Mass Tort/Product Liability** (Priority 13) *New*
14. **Real Estate/Closings** (Priority 14) *New*
15. **Landlord-Tenant** (Priority 15) *New*
16. **Family Law** (Priority 16) *New*
17. **Estate Planning** (Priority 17) *New*
18. **Business/Corporate** (Priority 18) *New*
19. **Criminal Defense** (Priority 19) *New*
20. **Traffic** (Priority 20) *New*
21. **Veteran Disability** (Priority 21) *New*

### Query Implementation

#### Base Filtering Logic
```sql
-- Ready to Call View
SELECT Id, Name, litify_pm__Display_Name__c, Referred_By_Name__c, 
       litify_pm__Status__c, Priority_Score__c, Case_Type_Reporting__c, 
       Type__c, Call_at_Date__c, litify_pm__Phone__c, litify_pm__Sign_Up_Method__c,
       Qualification_Status__c
FROM litify_pm__Intake__c 
WHERE (Test_Record__c = false OR Test_Record__c = null) 
  AND Type__c IN ('Worker Compensation', 'Personal Injury')
  AND (
    -- Standard statuses: show if Call_at_Date__c <= now
    (litify_pm__Status__c IN ('Lead Generated', 'In Contact/Under Review', 
                              'Missed Appointment', 'Intake Package Sent', 
                              'Attempting to Contact') 
     AND Call_at_Date__c <= :now)
    OR 
    -- Special handling for Questionnaire/Intake Scheduled
    ((litify_pm__Status__c = 'Questionnaire' 
      OR (litify_pm__Status__c = 'Intake Scheduled' 
          AND (litify_pm__Sign_Up_Method__c = 'E-Sign' 
               OR (litify_pm__Sign_Up_Method__c = 'Office' 
                   AND Call_at_Date__c <= :twoHoursFromNow)))) 
     AND Call_at_Date__c <= :fourHoursAgo)
  )
ORDER BY Priority_Score__c ASC, Call_at_Date__c ASC
```

#### View Modes
- **Ready to Call**: Complex time-based logic for immediate contact eligibility
- **Scheduled Calls**: Future appointments (`Call_at_Date__c > now`)

### Field Dependencies ✅ VERIFIED

#### Required Custom Fields (Retrieved from Production)
- **`Call_at_Date__c`**: DateTime formula field - primary sorting criteria
- **`Case_Type_Reporting__c`**: Text formula field - secondary priority factor
- **`Type__c`**: Picklist - base filtering (Worker Compensation, Personal Injury)
- **`Priority_Score__c`**: Number formula field - primary priority factor
- **`Test_Record__c`**: Checkbox - excludes test records
- **`Referred_By_Name__c`**: Text formula field - display purposes
- **`Qualification_Status__c`**: Text field - intake qualification status
- **`Appointment_Date__c`**: DateTime - used in Call_at_Date__c formula
- **`Follow_Up_Date_Time__c`**: DateTime - used in Call_at_Date__c formula

#### Managed Package Fields (Litify PM)
- **`litify_pm__Status__c`**: Picklist - primary priority driver
- **`litify_pm__Display_Name__c`**: Text - primary display name
- **`litify_pm__Phone__c`**: Phone - contact information
- **`litify_pm__Sign_Up_Method__c`**: Picklist - special time logic

### Platform Cache Architecture

#### Cache Configuration
- **Partition**: `local.LeadQueueCache`
- **TTL**: 1800 seconds (30 minutes)
- **Keys**: 
  - `assign_{recordId}` → `userId`
  - `user_{userId}` → `recordId`

#### Cache Operations
```apex
// Assignment
orgCache.put(ASSIGNMENT_CACHE_PREFIX + recordId, userId, ASSIGNMENT_TTL);
orgCache.put(USER_CACHE_PREFIX + userId, recordId, ASSIGNMENT_TTL);

// Release
orgCache.remove(ASSIGNMENT_CACHE_PREFIX + recordId);
orgCache.remove(USER_CACHE_PREFIX + userId);

// Check
String assignedUserId = (String) orgCache.get(ASSIGNMENT_CACHE_PREFIX + recordId);
```

---

## User Interface Implementation

### Dashboard Interface

#### Statistics Tiles (Clickable Filters)
- **All Leads**: Total records in current view
- **High Priority**: Lead Generated + Intake Scheduled count
- **In Contact**: In Contact/Under Review + Questionnaire + Missed Appointment count
- **No Contact**: Attempting to Contact count
- **Retainer Sent**: Intake Package Sent count

#### Filtering System
- **Server-side Filters**: Status, Case Type, Due Date with 300ms debouncing
- **Client-side Filters**: Tile-based filtering for quick category views
- **Combined Filtering**: Server and client filters work together
- **Persistent State**: Filter selections maintained during session

#### Data Table Features
- **Priority Ranking**: Shows queue position (1, 2, 3...)
- **Clickable Names**: Opens records with proper console navigation
- **Assignment Actions**: "Assign to Me" buttons for specific records
- **Assignment Status**: Shows which user has claimed each record
- **Timer Column**: Live assignment timer (MM:SS format) for current user's records
- **Qualification Status**: Displays intake qualification status for screening
- **Sortable Columns**: Click headers to sort (where applicable)

### Utility Bar Interface

#### Context-Aware Display
- **No Assignment**: Shows "Get Next Record" button only
- **Has Assignment**: Shows record details + "Release My Records" button
- **Assignment Details**: Record name, status, and live timer (MM:SS format)
- **Real-time Updates**: Timer updates every second for active assignments
- **Compact Design**: Optimized for utility bar space constraints

### Individual Record Interface

#### Claim Record Button Component
- **Smart Visibility**: Shows appropriate action based on assignment status
- **Conflict Detection**: Warns when user has different record assigned
- **Real-time Sync**: Updates every 5 seconds via platform cache
- **Visual Feedback**: Clear success/error states with progress indicators

---

## Performance & Scalability

### Small Office Optimization
- **Record Limits**: 1000 record query limit (appropriate for <100 daily records)
- **Efficient Queries**: User mode with field-level security enforcement
- **Batch Operations**: User name lookups batched for performance
- **Console Pre-warming**: Navigation services pre-loaded for faster tab opening

### Security Implementation
- **User Mode Queries**: `AccessLevel.USER_MODE` for all SOQL
- **Field Validation**: `validateFieldAccess()` checks required field permissions
- **Input Validation**: All user inputs validated and sanitized
- **Permission Enforcement**: Component respects field-level security

### Error Handling
- **Graceful Degradation**: Functions with limited features when cache unavailable
- **User-Friendly Messages**: Technical errors translated to business language
- **Comprehensive Logging**: Debug logs for troubleshooting
- **Retry Logic**: Automatic retries for transient failures

---

## Deployment Architecture

### Component Structure
```
force-app/main/default/
├── lwc/
│   ├── leadQueueViewer/          # Main queue component
│   └── claimRecordButton/        # Record page button
├── classes/
│   ├── LeadQueueService.cls      # Core business logic
│   └── CustomIntakeTriggerHandler.cls  # Auto-release trigger
├── objects/litify_pm__Intake__c/
│   └── fields/                   # Required custom fields
├── applications/
│   └── Lead_Queue_App.app-meta.xml    # Lightning App
├── permissionsets/
│   └── LeadQueue_Access.permissionset-meta.xml
└── tabs/
    └── Lead_Queue.tab-meta.xml
```

### Permission Requirements
- **Object Access**: Read `litify_pm__Intake__c`
- **Field Access**: Read access to all required fields
- **Apex Access**: Execute `LeadQueueService` methods
- **App Access**: Lead Queue App visibility
- **Cache Access**: Platform Cache partition usage

### Testing Coverage
- **Apex Tests**: 37 test methods with 100% pass rate (verified in production deployment)
- **Business Logic**: All assignment and validation scenarios covered
- **Priority Testing**: New case type priority scenarios validated with `testNewCaseTypePriorityOrdering()`
- **Error Scenarios**: Exception handling and edge cases tested
- **Integration**: Cross-component functionality verified
- **Production Validation**: Successfully deployed to shulman org with full test execution

---

## Recent Enhancements (September 2025)

### Priority System Updates
- **Case Type Priority Reordering**: Updated secondary priority mapping to reflect current business needs
- **New Case Types**: Added "WC & PI" (Priority 4) and "Other" (Priority 7) to priority matrix
- **Production Deployment**: Changes deployed to shulman org with full test coverage (37/37 tests passing)
- **Backend Updates**: `LeadQueueService.CASE_TYPE_PRIORITY` map updated and synchronized

### Timer Functionality in Full Dashboard
- **Timer Column**: Added as the rightmost column in the Lead Queue table
- **Real-time Updates**: Timer displays MM:SS format and updates every second
- **User-specific Display**: Only shows timer for records assigned to the current user
- **Assignment Tracking**: Utilizes existing sessionStorage system for timestamp tracking
- **Consistent Experience**: Matches timer functionality from utility bar interface

### Qualification Status Column
- **Strategic Placement**: Positioned between Case Type and Call Date columns
- **Data Source**: Pulls from `Qualification_Status__c` field on the Intake object
- **Screening Support**: Helps users prioritize qualification and screening tasks
- **Field Integration**: Included in SOQL queries and field access validation
- **Display Enhancement**: Provides additional context for intake processing

### Technical Implementation Details

#### Timer Architecture
```javascript
// Real-time timer calculation
getRecordAssignmentTimer(recordId, assignedTo) {
    // Only shows for current user's assignments
    // Calculates time difference from assignment timestamp
    // Returns MM:SS format for active timers
    // Shows "Assigned" for other users' records
}

// Timer refresh mechanism
refreshTableTimers() {
    // Updates timer values in records array every second
    // Triggers reactive updates in Lightning datatable
}
```

#### Data Model Updates
```sql
-- Updated REQUIRED_FIELDS to include:
'Qualification_Status__c'

-- Updated field validation array:
'Qualification_Status__c'
```

#### User Experience Improvements
- **Consistent Timer Display**: Both utility bar and full dashboard show identical timer format
- **Non-disruptive Updates**: Timer updates don't interfere with user interactions
- **Performance Optimized**: Minimal overhead for timer calculations and updates
- **Memory Management**: Proper cleanup of timer intervals on component disconnect

---

## Business Rules & Validation

### Assignment Rules
1. **Single Assignment Limit**: Users can only have one assigned record at a time
2. **Priority Enforcement**: Automatic assignment follows priority score ranking
3. **Type Restriction**: Only Worker Compensation and Personal Injury records eligible
4. **Time Validation**: Records must meet view-specific time criteria
5. **Auto-Release Triggers**: Assignments released when Appointment_Date__c or Follow_Up_Date_Time__c change

### Data Quality Requirements
- **Required Fields**: All display and sorting fields must be populated
- **Valid Statuses**: Only records with approved status values included
- **Test Record Exclusion**: Test records filtered out via Test_Record__c checkbox
- **Case Type Validation**: Case_Type_Reporting__c must contain valid priority values

### Field Dependencies
- **Call_at_Date__c Formula**: Handles Appointment_Date__c and Follow_Up_Date_Time__c precedence
- **Priority_Score__c Formula**: Calculated priority based on status and case type
- **Case_Type_Reporting__c Formula**: Derived from Type__c and Case_Type__c values
- **Referred_By_Name__c Formula**: Lookup to referral source name

---

## Migration Notes

### From Legacy DICE Queue
- ✅ **Functionality Parity**: All original features implemented and enhanced
- ✅ **Performance Improvement**: Modern LWC vs legacy Visualforce
- ✅ **Mobile Compatibility**: Responsive design for all devices
- ✅ **Console Integration**: Optimized for modern Salesforce interface
- ✅ **Real-time Features**: Live updates and assignment tracking

### Data Migration
- **Field Mapping**: All legacy field references updated to current schema
- **Priority Logic**: Enhanced with formula field calculations
- **Assignment System**: Upgraded from session-based to platform cache
- **User Training**: Documentation and training materials provided

---

*This implementation successfully modernizes the intake queue management system while maintaining compatibility with existing Salesforce environments and providing enhanced functionality for small law office workflows.*