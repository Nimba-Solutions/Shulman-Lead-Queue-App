/**
 * Shared utility functions for Lead Queue components
 */

export class SharedUtils {
    
    /**
     * Get user-friendly error message from Salesforce exception
     */
    static getErrorMessage(error) {
        const userFriendlyMessages = {
            'FIELD_CUSTOM_VALIDATION_EXCEPTION': 'Invalid data provided',
            'INSUFFICIENT_ACCESS_OR_READONLY': 'Access denied',
            'QUERY_TIMEOUT': 'Request timed out, please try again',
            'REQUIRED_FIELD_MISSING': 'Required information is missing',
            'FIELD_INTEGRITY_EXCEPTION': 'Data validation error'
        };
        
        const errorCode = error?.body?.exceptionType || error?.name;
        return userFriendlyMessages[errorCode] || 'An error occurred. Please contact your administrator.';
    }

    /**
     * Format date/time for display
     */
    static formatTime(dateTimeValue) {
        if (!dateTimeValue) return '';
        
        try {
            const dateTime = new Date(dateTimeValue);
            return dateTime.toLocaleTimeString('en-US', {
                hour: 'numeric',
                minute: '2-digit',
                hour12: true
            });
        } catch (error) {
            return '';
        }
    }

    /**
     * Format call date and time for display
     */
    static formatCallDateTime(dateTimeValue) {
        if (!dateTimeValue) return '';
        
        try {
            const dateTime = new Date(dateTimeValue);
            return dateTime.toLocaleDateString('en-US', {
                month: '2-digit',
                day: '2-digit',
                year: 'numeric'
            }) + ' ' + dateTime.toLocaleTimeString('en-US', {
                hour: 'numeric',
                minute: '2-digit',
                hour12: true
            });
        } catch (error) {
            return '';
        }
    }

    /**
     * Constants for the application
     */
    static get CONSTANTS() {
        return {
            HIGH_PRIORITY_THRESHOLD: 22,
            MEDIUM_PRIORITY_THRESHOLD: 55,
            REFRESH_INTERVAL: 30000
        };
    }

    /**
     * Due date filter options
     */
    static get dueDateOptions() {
        return [
            { label: 'All Dates', value: '' },
            { label: 'Due Today', value: 'today' },
            { label: 'Due This Week', value: 'thisWeek' },
            { label: 'Due Next Week', value: 'nextWeek' }
        ];
    }
}