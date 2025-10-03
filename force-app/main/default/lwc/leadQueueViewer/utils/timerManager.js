/**
 * Timer management utilities for Lead Queue
 * Handles assignment timers, real-time updates, and timestamp processing
 */

export class TimerManager {
    
    constructor(component) {
        this.component = component;
    }

    /**
     * Get assignment timer for a specific record
     */
    getRecordAssignmentTimer(recordId, assignedTo, assignedTimestamp) {
        if (!assignedTo) {
            return '';
        }
        
        // Use server-provided timestamp if available
        if (assignedTimestamp) {
            try {
                // Handle both Long timestamp (from server) and ISO string formats
                let assignedTime;
                if (typeof assignedTimestamp === 'number') {
                    // Server returns Long timestamp (milliseconds since epoch)
                    assignedTime = new Date(assignedTimestamp);
                } else {
                    // ISO string format
                    assignedTime = new Date(assignedTimestamp);
                }
                
                const diffMs = this.component.currentTime - assignedTime;
                const totalSeconds = Math.floor(diffMs / 1000);
                
                // Handle negative time (future timestamps) gracefully
                if (totalSeconds < 0) {
                    return '00:00';
                }
                
                const minutes = Math.floor(totalSeconds / 60);
                const seconds = totalSeconds % 60;
                
                return `${minutes.toString().padStart(2, '0')}:${seconds.toString().padStart(2, '0')}`;
            } catch (error) {
                console.log('Could not parse server assignment timestamp:', error);
                console.log('Timestamp value:', assignedTimestamp, 'Type:', typeof assignedTimestamp);
            }
        }
        
        // If no timestamp available but record is assigned, show this as a fallback
        // This shouldn't happen in normal operation with Platform Cache working
        return 'Assigned';
    }

    /**
     * Get utility bar timer for current user only
     */
    getUtilityBarTimer() {
        // Only show timer for records assigned to the current user
        if (this.component.hasAssignments && this.component.userAssignedRecordIds && this.component.userAssignedRecordIds.length > 0) {
            // Get the user's assigned record ID (should only be one)
            const assignedRecordId = this.component.userAssignedRecordIds[0];
            const timestamp = this.component.userAssignmentTimestamps[assignedRecordId];
            
            console.log('Utility bar - assignedRecordId:', assignedRecordId);
            console.log('Utility bar - timestamp:', timestamp);
            
            if (timestamp) {
                const timerValue = this.calculateTimerValue(timestamp);
                return timerValue ? `Time Assigned: ${timerValue}` : 'Time Assigned: --:--';
            }
            
            return 'Time Assigned: --:--';
        }
        
        return '';
    }

    /**
     * Helper method to calculate timer value from timestamp
     */
    calculateTimerValue(assignmentTimestamp) {
        if (!assignmentTimestamp) {
            return null;
        }
        
        try {
            // Handle both Long timestamp (from server) and ISO string formats
            let assignedTime;
            if (typeof assignmentTimestamp === 'number') {
                assignedTime = new Date(assignmentTimestamp);
            } else {
                assignedTime = new Date(assignmentTimestamp);
            }
            
            const diffMs = this.component.currentTime - assignedTime;
            const totalSeconds = Math.floor(diffMs / 1000);
            
            // Handle negative time gracefully
            if (totalSeconds < 0) {
                return '00:00';
            }
            
            const minutes = Math.floor(totalSeconds / 60);
            const seconds = totalSeconds % 60;
            
            return `${minutes.toString().padStart(2, '0')}:${seconds.toString().padStart(2, '0')}`;
        } catch (error) {
            console.log('Could not parse assignment timestamp:', error);
            console.log('Timestamp value:', assignmentTimestamp, 'Type:', typeof assignmentTimestamp);
            return null;
        }
    }

    /**
     * Refresh all table timers
     */
    refreshTableTimers() {
        // Only update timer values if there are assigned records to optimize performance
        if (this.component.records && this.component.records.length > 0 && this.component.hasAssignments) {
            // Create a map of original records for faster lookup
            const originalRecordMap = new Map();
            this.component.originalRecords.forEach(orig => {
                originalRecordMap.set(orig.Id, orig);
            });
            
            this.component.records = this.component.records.map(record => {
                // Skip timer update if record is not assigned
                if (!record.assignedTo) {
                    return record;
                }
                
                // Use the record ID directly - no modification needed
                const originalRecord = originalRecordMap.get(record.Id);
                const timestamp = originalRecord ? originalRecord.assignmentTimestamp : null;
                
                return {
                    ...record,
                    assignmentTimer: this.getRecordAssignmentTimer(record.Id, record.assignedTo, timestamp)
                };
            });
        }
    }

    /**
     * Start timer interval for real-time updates
     */
    startTimerUpdates() {
        // Clear any existing timer interval
        if (this.component.timerInterval) {
            clearInterval(this.component.timerInterval);
            this.component.timerInterval = null;
        }

        // Start live timer updates
        this.component.timerInterval = setInterval(() => {
            this.component.currentTime = new Date();
            this.refreshTableTimers();
        }, 1000); // Update every second
    }

    /**
     * Stop timer updates
     */
    stopTimerUpdates() {
        if (this.component.timerInterval) {
            clearInterval(this.component.timerInterval);
            this.component.timerInterval = null;
        }
    }

    /**
     * Get assigned record info for tooltip
     */
    getAssignedRecordInfo() {
        if (this.component.hasAssignments && this.component.records.length > 0) {
            // Find record assigned to current user using proper ID matching
            const assignedRecord = this.component.records.find(record => {
                if (!record.assignedTo || !this.component.userAssignedRecordIds) {
                    return false;
                }
                
                const originalRecordId = record.Id.endsWith('-assigned') 
                    ? record.Id.slice(0, -9) 
                    : record.Id;
                
                return this.component.userAssignedRecordIds.includes(originalRecordId);
            });
            
            return assignedRecord ? `Currently assigned: ${assignedRecord.litify_pm__Display_Name__c || assignedRecord.Name}` : 'Record assigned';
        }
        return '';
    }

    /**
     * Get assigned record display name for utility bar
     */
    getAssignedRecordDisplayName() {
        if (this.component.hasAssignments && this.component.records.length > 0) {
            // Find record assigned to current user using proper ID matching
            const assignedRecord = this.component.records.find(record => {
                if (!record.assignedTo || !this.component.userAssignedRecordIds) {
                    return false;
                }
                
                const originalRecordId = record.Id.endsWith('-assigned') 
                    ? record.Id.slice(0, -9) 
                    : record.Id;
                
                return this.component.userAssignedRecordIds.includes(originalRecordId);
            });
            
            return assignedRecord ? (assignedRecord.litify_pm__Display_Name__c || assignedRecord.Name) : 'Assigned Record';
        }
        return '';
    }

    /**
     * Get assigned record status for utility bar
     */
    getAssignedRecordStatus() {
        if (this.component.hasAssignments && this.component.records.length > 0) {
            // Find record assigned to current user using proper ID matching
            const assignedRecord = this.component.records.find(record => {
                if (!record.assignedTo || !this.component.userAssignedRecordIds) {
                    return false;
                }
                
                const originalRecordId = record.Id.endsWith('-assigned') 
                    ? record.Id.slice(0, -9) 
                    : record.Id;
                
                return this.component.userAssignedRecordIds.includes(originalRecordId);
            });
            
            if (assignedRecord && assignedRecord.Status) {
                return `Status: ${assignedRecord.Status}`;
            }
        }
        return null;
    }
}